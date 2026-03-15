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
    private let clipboardMonitor: ClipboardMonitor
    private let escCancelManager: GlobalHotkeyManager
    let transcriptionHistory: TranscriptionHistory
    let overrides: ConversationOverrides

    @ObservationIgnored var session: PipelineSession?

    @ObservationIgnored private var originalCapture: CapturedContext?
    @ObservationIgnored private var accumulatedCaptures: [CapturedContext] = []

    @ObservationIgnored var pillResetTask: Task<Void, Never>?

    @ObservationIgnored var autoDismissTask: Task<Void, Never>?

    @ObservationIgnored private var expandTimerTask: Task<Void, Never>?

    @ObservationIgnored var onWillStartInput: (() -> Void)?

    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

    var isPanelVisible: Bool { panel.isVisible }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
    }

    func hideModeSwitcher() {
        panel.hideModeSwitcher()
    }

    static let successIndicatorDuration: Duration = .seconds(2)
    static let pillErrorDisplayDuration: Duration = .seconds(1.5)
    static let pillFlashDuration: Duration = .seconds(1)
    static let errorIndicatorDuration: Duration = .seconds(10)
    private static let escapeKeyCode: CGKeyCode = 53

    init(
        settings: AppSettings,
        panel: CapturePanel,
        recordingIndicator: RecordingIndicatorPanel,
        audioRecorder: AudioRecorder,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        escCancelManager: GlobalHotkeyManager,
        transcriptionHistory: TranscriptionHistory,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.panel = panel
        self.recordingIndicator = recordingIndicator
        self.audioRecorder = audioRecorder
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
        self.escCancelManager = escCancelManager
        self.transcriptionHistory = transcriptionHistory
        self.overrides = overrides
    }

    func showFromHistory(conversation: Conversation, canContinue: Bool) {
        let turns = conversation.turns.map { turn in
            ConversationTurn(input: turn.input, output: turn.output, captures: turn.captures)
        }

        session = PipelineSession()
        session?.conversationTurns = turns
        session?.conversationID = conversation.id
        if canContinue {
            session?.followUpContext = conversation.latestOutput
        }

        configurePanelAndShow(conversationTurns: turns, segments: [InputSegment()])
        if conversation.hadExternalProcessing {
            panel.setProcessedByModeName(conversation.modeName)
        }
        Logger.app.info("Capture view shown from history (canContinue=\(canContinue))")
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

        setupEscCancelForCollapsed()
    }

    private func setupEscCancelForCollapsed() {
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.dismissOverlay()
        }
        escCancelManager.onKeyUp = nil
        _ = escCancelManager.register(keyCode: Self.escapeKeyCode, modifiers: [])
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
        escCancelManager.isEnabled = false
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        originalCapture = nil
        accumulatedCaptures = []
    }

    func configurePanelAndShow(
        conversationTurns: [ConversationTurn] = [],
        segments: [InputSegment]? = nil
    ) {
        rewirePanelCallbacks()

        let resolvedSegments = segments ?? [InputSegment()]

        panel.show(
            settings: settings,
            overrides: overrides,
            conversationTurns: conversationTurns,
            segments: resolvedSegments,
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
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
            overrides.clearIfCompletedPipeline()
            if session == nil {
                session = PipelineSession()
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
        configurePanelAndShow()
        panel.setPhase(.idle)
        panel.minimize()

        // Capture selection in background — populates segments when ready
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        Task {
            guard let capturedText = await selectionCapturer.capture(bundleIdentifier: bundleID, pid: pid) else { return }
            let context = CapturedContext(text: capturedText, source: .selection)
            session?.captures = [context]
            originalCapture = context
            panel.setSegments([InputSegment(capture: context)])
            panel.signalClipboardCapture()
        }

        Logger.app.info("Capture view: pill shown for new capture")
    }

    private func startExpandTimer() {
        expandTimerTask?.cancel()
        let delayMs = settings.pushToTypeExpandDelay
        expandTimerTask = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            guard panel.isVisible, panel.isMinimized else { return }
            panel.expand()
        }
    }

    private func collapseOverlay() {
        panel.minimize()
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
        escCancelManager.isEnabled = false
        Logger.app.info("Capture view: expanded from pill with \(newCaptures.count) clipboard captures")
    }

    func dismissOverlay() {
        Task { await clipboardMonitor.stop() }
        escCancelManager.isEnabled = false
        expandTimerTask?.cancel()
        expandTimerTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        panel.dismiss()
        session = nil
        originalCapture = nil
        accumulatedCaptures = []
        Logger.app.info("Capture view dismissed (capture preserved in history)")
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
        dismissOverlay()
    }

}
