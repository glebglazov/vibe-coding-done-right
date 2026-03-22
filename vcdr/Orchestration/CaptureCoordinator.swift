import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class CaptureCoordinator {
    let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    let panel: CapturePanel
    let recordingIndicator: RecordingIndicatorPanel
    private let audioRecorder: AudioRecorder
    private let selectionCapturer: SelectionCapturer
    let clipboardMonitor: ClipboardMonitor
    let transcriptionHistory: TranscriptionHistory
    let overrides: ConversationOverrides

    @ObservationIgnored var session: PipelineSession?

    @ObservationIgnored private var originalCapture: CapturedContext?
    @ObservationIgnored var accumulatedCaptures: [CapturedContext] = []

    @ObservationIgnored var pillResetTask: Task<Void, Never>?

    @ObservationIgnored var autoDismissTask: Task<Void, Never>?

    @ObservationIgnored private var expandTimerTask: Task<Void, Never>?

    @ObservationIgnored var quickActionTask: Task<Void, Never>?

    @ObservationIgnored var onWillStartInput: (() -> Void)?

    /// Signals RecordingCoordinator to enable/disable the cancel hotkey for pill state.
    @ObservationIgnored var onCancelHotkeyEnabled: ((Bool) -> Void)?

    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

    var isPanelVisible: Bool { panel.isVisible }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
    }

    func showModeSwitcherOnPill(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
        panel.expand()
    }

    func hideModeSwitcher() {
        panel.hideModeSwitcher()
    }

    func hideModeSwitcherAndMinimize() {
        panel.hideModeSwitcher()
        panel.minimize()
    }

    static let successIndicatorDuration: Duration = .seconds(2)
    static let pillErrorDisplayDuration: Duration = .seconds(1.5)
    static let pillFlashDuration: Duration = .seconds(1)
    static let errorIndicatorDuration: Duration = .seconds(10)

    init(
        settings: AppSettings,
        panel: CapturePanel,
        recordingIndicator: RecordingIndicatorPanel,
        audioRecorder: AudioRecorder,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        transcriptionHistory: TranscriptionHistory,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.panel = panel
        self.recordingIndicator = recordingIndicator
        self.audioRecorder = audioRecorder
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
        self.transcriptionHistory = transcriptionHistory
        self.overrides = overrides
    }

    func showFromHistory(conversation: Conversation, canContinue: Bool) {
        // Split turns: completed (with output) → conversation history,
        // last unprocessed turn → editor segments (same as mid-capture state).
        var completedTurns: [ConversationTurn] = []
        var editorSegments: [InputSegment] = [InputSegment()]

        for turn in conversation.turns where turn.output != nil {
            completedTurns.append(turn)
        }

        // If the last turn has no output, restore its segments into the editor
        if let lastTurn = conversation.turns.last, lastTurn.output == nil {
            editorSegments = lastTurn.inputSegments.isEmpty ? [InputSegment()] : lastTurn.inputSegments
        }

        session = PipelineSession()
        session?.conversationTurns = completedTurns
        // Use the SAME conversation ID — fork only happens on mutation
        session?.conversationID = conversation.id
        // Always set historySourceConversationID so fork is triggered on first write
        session?.historySourceConversationID = conversation.id
        if let latestOutput = conversation.latestOutput {
            session?.followUpContext = latestOutput
        }

        configurePanelAndShow(conversationTurns: completedTurns, inputSegments: editorSegments)
        if conversation.hadExternalProcessing {
            panel.setProcessedByModeName(conversation.modeName)
        }
        Logger.app.info("Capture view shown from history")
    }

    func setupHotkey() {
        let binding = settings.pushToTypeHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Push-to-type hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                self?.handlePushToTypeKeyDown()
            }
        }
        hotkeyManager.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.handlePushToTypeKeyUp()
            }
        }

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)

    }

    func rewirePanelCallbacks() {
        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }
    }

    private func clearSubmissionCallbacks() {
        Task { await clipboardMonitor.stop() }
        onCancelHotkeyEnabled?(false)
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        originalCapture = nil
        accumulatedCaptures = []
    }

    func configurePanelAndShow(
        conversationTurns: [ConversationTurn] = [],
        inputSegments: [InputSegment]? = nil,
        minimized: Bool = false
    ) {
        rewirePanelCallbacks()

        let resolvedSegments = inputSegments ?? [InputSegment()]

        panel.show(
            settings: settings,
            overrides: overrides,
            conversationTurns: conversationTurns,
            inputSegments: resolvedSegments,
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
            minimized: minimized,
            onSubmit: { [weak self] text in
                self?.clearSubmissionCallbacks()
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )

        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            self.clearSubmissionCallbacks()
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
        }
    }

    private func handlePushToTypeKeyDown() {
        if panel.isVisible && !panel.isMinimized {
            collapseOverlay()
        } else if panel.isVisible && panel.isMinimized {
            Task { await expandFromCollapsed() }
        } else {
            onWillStartInput?()
            recordingIndicator.hide()
            overrides.clearIfCompletedPipeline()
            if session == nil {
                session = PipelineSession()
                session?.conversationID = UUID()
            }
            showPillForNewCapture()
            startExpandTimer()
        }
    }

    private func handlePushToTypeKeyUp() {
        expandTimerTask?.cancel()
        expandTimerTask = nil
    }

    private func showPillForNewCapture() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp

        // Show pill immediately with empty content
        configurePanelAndShow(minimized: true)
        panel.setPhase(.idle)
        panel.minimize()
        onCancelHotkeyEnabled?(true)

        // Capture selection in background — populates segments when ready.
        // Start clipboard monitoring after capture completes (same pattern as
        // toggle-recording) so copies during the pill state register immediately.
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        Task {
            let capturedText = await selectionCapturer.capture(bundleIdentifier: bundleID, pid: pid)
            if let capturedText {
                Logger.app.info("Push-to-type: storing captured selection (\(capturedText.count) chars): \"\(capturedText.prefix(80))\"")
                let context = CapturedContext(text: capturedText, source: .selection)
                session?.captures = [context]
                originalCapture = context
                panel.setSegments([InputSegment(capture: context)])
                panel.signalClipboardCapture()
            }

            // Take baseline after SelectionCapturer finishes — its clipboard
            // copy/read/restore can bump changeCount and cause false positives.
            let freshBaseline = NSPasteboard.general.changeCount
            await clipboardMonitor.start(baselineChangeCount: freshBaseline) { [weak self] _ in
                self?.panel.signalClipboardCapture()
            }
        }

        Logger.app.info("Capture view: pill shown for new capture")
    }

    private func startExpandTimer() {
        expandTimerTask?.cancel()
        let delayMs = settings.pushToTypeExpandDelay
        if delayMs <= 0 {
            // Expand immediately — no pill state
            guard panel.isVisible, panel.isMinimized else { return }
            panel.expand()
            return
        }
        expandTimerTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            guard panel.isVisible, panel.isMinimized else { return }
            panel.expand()
        }
    }

    private func collapseOverlay() {
        panel.minimize()
        onCancelHotkeyEnabled?(true)
        Task {
            await clipboardMonitor.start { [weak self] _ in
                self?.panel.signalClipboardCapture()
            }
        }
        Logger.app.info("Capture view: collapsed to pill")
    }

    private func expandFromCollapsed() async {
        let newCaptures = await clipboardMonitor.stop()

        if !newCaptures.isEmpty {
            for capturedText in newCaptures {
                let context = CapturedContext(text: capturedText, source: .clipboard)
                accumulatedCaptures.append(context)
                panel.addClipboardCapture(context)
            }
            session?.captures = panel.allCaptures
        }

        panel.expand()
        onCancelHotkeyEnabled?(false)
        Logger.app.info("Capture view: expanded from pill with \(newCaptures.count) clipboard captures")
    }

    func dismissOverlay(saveToHistory: Bool = true) {
        // Persist any non-empty input to history before tearing down the session.
        // For the recording flow a draft already exists (populateWithTranscription wrote it);
        // this updates it with the latest panel text. For push-to-type this creates
        // the initial history entry so dismissed captures are never lost.
        if saveToHistory {
            preserveCurrentInputToHistory()
        }

        Task { await clipboardMonitor.stop() }
        onCancelHotkeyEnabled?(false)
        expandTimerTask?.cancel()
        expandTimerTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        quickActionTask?.cancel()
        quickActionTask = nil
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        panel.dismiss()
        recordingIndicator.showDismissed()
        session = nil
        originalCapture = nil
        accumulatedCaptures = []
        overrides.clearAll()
        Logger.app.info("Capture view dismissed")
    }

    func dismissIfActive() {
        guard panel.isVisible else { return }
        dismissOverlay()
    }

    func cancelCapture() {
        if let conversationID = session?.conversationID,
           let conversation = transcriptionHistory.conversations.first(where: { $0.id == conversationID }) {
            transcriptionHistory.removeConversation(conversation)
            Logger.app.info("Capture cancelled and removed from history")
        }
        // Use dismissOverlay's cleanup but override the pill with a cancel indicator.
        // Pass saveToHistory: false — cancel explicitly removes from history above.
        dismissOverlay(saveToHistory: false)
        recordingIndicator.showCancelled()
    }

    // MARK: - History Preservation

    /// Saves the current panel content to history on dismiss so no input is lost.
    private func preserveCurrentInputToHistory() {
        guard let session, let conversationID = session.conversationID else { return }

        // Viewing history without mutation — Escape discards, original stays intact
        if session.historySourceConversationID != nil { return }

        let segments = panel.viewModel?.inputSegments ?? []
        let hasContent = segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.capture != nil }
        guard hasContent else { return }

        recordOrUpdateHistory(
            conversationID: conversationID,
            inputSegments: segments, output: nil,
            mode: settings.activeMode
        )
    }

}
