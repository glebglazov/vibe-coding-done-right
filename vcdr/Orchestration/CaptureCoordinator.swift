import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class CaptureCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    let panel: CapturePanel
    private let recordingIndicator: RecordingIndicatorPanel
    private let audioRecorder: AudioRecorder
    private let selectionCapturer: SelectionCapturer
    private let clipboardMonitor: ClipboardMonitor
    private let escCancelManager: GlobalHotkeyManager
    private let transcriptionHistory: TranscriptionHistory
    private let overrides: ConversationOverrides

    /// Per-pipeline-run state. Non-nil while a pipeline is in progress.
    /// Private to enforce explicit handoff — use `followUpSnapshot()` to read.
    private var session: PipelineSession?

    /// The initial AX capture from when the session was opened.
    private var originalCapture: CapturedContext?
    /// All Cmd+C captures accumulated across collapse/expand cycles.
    private var accumulatedCaptures: [CapturedContext] = []

    /// Called when the capture overlay is about to show.
    var onWillStartInput: (() -> Void)?

    /// Whether the capture panel is visible and can host a contextual mode switcher
    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    /// Whether a contextual mode switcher is currently showing inside the capture panel
    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

    /// Whether the capture panel is visible in any state
    var isPanelVisible: Bool { panel.isVisible }

    /// Returns a snapshot of the current session state for follow-up recordings.
    /// RecordingCoordinator calls this instead of reading `session` directly.
    func followUpSnapshot() -> FollowUpSnapshot? {
        guard let session else { return nil }
        return FollowUpSnapshot(
            conversationID: session.conversationID,
            conversationTurns: session.conversationTurns,
            followUpContext: session.followUpContext,
            captures: session.captures,
            previousActiveApp: session.previousActiveApp
        )
    }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
    }

    func hideModeSwitcher() {
        panel.hideModeSwitcher()
    }

    func updateOutputDestinationOverride(_ id: UUID?) {
        panel.updateOutputDestinationOverride(id)
    }

    // MARK: - Constants

    private static let successIndicatorDuration: Duration = .seconds(2)
    /// How long the error X shows on the pill before returning to idle
    private static let pillErrorDisplayDuration: Duration = .seconds(1.5)
    /// How long the cancelled/success icon shows on the pill before returning to idle
    private static let pillFlashDuration: Duration = .seconds(1)
    private static let errorIndicatorDuration: Duration = .seconds(10)
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

    // MARK: - Public API (called by RecordingCoordinator)

    /// Shows the result of a quick action that routed to the output panel.
    /// Creates a conversation turn with input→output and opens the capture view.
    func showQuickActionResult(
        input: String,
        output: String,
        captures: [CapturedContext],
        conversationID: UUID,
        previousActiveApp: NSRunningApplication?,
        hadExternalProcessing: Bool
    ) {
        let turn = ConversationTurn(input: input, output: output, captures: captures)

        panel.dismiss()

        session = PipelineSession()
        session?.previousActiveApp = previousActiveApp
        session?.captures = captures
        session?.conversationID = conversationID
        session?.conversationTurns = [turn]
        session?.followUpContext = output

        // showPanelWithText reads session.conversationTurns, so the turn is shown
        showPanelWithText("")

        transcriptionHistory.recordTurn(
            conversationID: conversationID,
            input: input,
            output: output,
            captures: captures,
            modeID: settings.activeModeID,
            modeName: settings.activeMode.name,
            hadExternalProcessing: hadExternalProcessing
        )

        overrides.markPipelineCompleted()
        Logger.app.info("Capture view: quick action result shown")
    }

    /// Shows the Capture View with transcribed text after recording completes.
    /// Inserts text at cursor if panel is already open, otherwise creates new session.
    /// Saves to capture history immediately.
    func populateWithTranscription(
        _ text: String,
        captures: [CapturedContext],
        conversationID: UUID,
        previousActiveApp: NSRunningApplication?
    ) {
        if panel.isVisible {
            // Panel already open — insert at cursor
            panel.setRecording(false)
            panel.setProcessing(false)
            panel.insertTextAtCursor(text)
            // Replace captures — the `captures` parameter already contains the full
            // set from this recording run (including any carried over from the session),
            // so appending would duplicate prior captures on each follow-up.
            session?.captures = captures
            panel.updateCaptures(captures)
        } else {
            // Fresh session — show panel with text
            session = PipelineSession()
            session?.previousActiveApp = previousActiveApp
            session?.captures = captures
            session?.conversationID = conversationID
            showPanelWithText(text)
        }
        panel.expand()

        // Save to capture history immediately (before any processing)
        transcriptionHistory.recordTurn(
            conversationID: session?.conversationID ?? conversationID,
            input: text,
            output: text,
            captures: captures,
            modeID: settings.activeModeID,
            modeName: settings.activeMode.name,
            hadExternalProcessing: false
        )
    }

    /// Notifies the capture view that recording has started.
    func notifyRecordingStarted() {
        if panel.isVisible {
            panel.setRecording(true)
        } else {
            showPanelMinimized(phase: .recording)
        }
    }

    /// Notifies the capture view that recording was cancelled.
    func notifyRecordingCancelled() {
        panel.setRecording(false)
    }

    /// Notifies that transcription produced no result (e.g. no speech detected).
    /// Briefly shows an error state on the pill, then returns to idle.
    func notifyTranscriptionFailed() {
        panel.setRecording(false)
        panel.setProcessing(false)
        if panel.isVisible {
            panel.showPillError()
            Task {
                try? await Task.sleep(for: Self.pillErrorDisplayDuration)
                panel.setPillPhase(.idle)
            }
        }
    }

    /// Briefly flashes the cancelled icon on the pill, then returns to idle.
    func notifyCancelled() {
        panel.setRecording(false)
        panel.setProcessing(false)
        if panel.isVisible {
            panel.setPillPhase(.cancelled)
            if !panel.isMinimized { panel.minimize(phase: .cancelled) }
            Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                panel.setPillPhase(.idle)
            }
        }
    }

    /// Briefly flashes the success icon on the pill, then returns to idle.
    func notifySuccess() {
        if panel.isVisible {
            panel.setPillPhase(.success)
            if !panel.isMinimized { panel.minimize(phase: .success) }
            Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                panel.setPillPhase(.idle)
            }
        }
    }

    /// Notifies that recording stopped and transcription has started.
    /// Transitions the capture panel from recording state to processing state.
    func notifyTranscribing() {
        panel.setRecording(false)
        if panel.isVisible {
            if panel.isMinimized {
                panel.minimize(phase: .processing)
            } else {
                // Panel is expanded — show processing inline instead of minimizing
                panel.setProcessing(true)
            }
        }
    }

    // MARK: - Show From History

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

        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }

        panel.show(
            settings: settings,
            conversationTurns: turns,
            captures: [],
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
            onSubmit: { [weak self] text in
                Task { await self?.clipboardMonitor.stop() }
                self?.escCancelManager.isEnabled = false
                self?.panel.onFocusLost = nil
                self?.panel.onPillClicked = nil
                self?.originalCapture = nil
                self?.accumulatedCaptures = []
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )
        panel.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))

        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            Task { await self.clipboardMonitor.stop() }
            self.escCancelManager.isEnabled = false
            self.panel.onFocusLost = nil
            self.panel.onPillClicked = nil
            self.originalCapture = nil
            self.accumulatedCaptures = []
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
        }

        Logger.app.info("Capture view shown from history (canContinue=\(canContinue))")
    }

    // MARK: - Push-to-Type Hotkey

    func setupHotkey() {
        let binding = settings.pushToTypeHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Push-to-type hotkey unassigned, unregistered")
            return
        }

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
                await self?.toggleOverlay()
            }
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)

        setupEscCancelForCollapsed()
    }

    func updateHotkey() {
        setupHotkey()
    }

    private func setupEscCancelForCollapsed() {
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.dismissOverlay()
        }
        escCancelManager.onKeyUp = nil
        _ = escCancelManager.register(keyCode: Self.escapeKeyCode, modifiers: [])
    }

    // MARK: - Overlay Lifecycle

    private func toggleOverlay() async {
        if panel.isVisible && !panel.isMinimized {
            collapseOverlay()
        } else if panel.isVisible && panel.isMinimized {
            await expandFromCollapsed()
        } else {
            onWillStartInput?()

            overrides.clearIfCompletedPipeline()
            if session == nil {
                session = PipelineSession()
            }
            await showOverlay()
        }
    }

    private func showOverlay() async {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp

        let overlayTurns = session?.conversationTurns ?? []

        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }

        panel.show(
            settings: settings,
            conversationTurns: overlayTurns,
            captures: [],
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
            onSubmit: { [weak self] text in
                Task { await self?.clipboardMonitor.stop() }
                self?.escCancelManager.isEnabled = false
                self?.panel.onFocusLost = nil
                self?.panel.onPillClicked = nil
                self?.originalCapture = nil
                self?.accumulatedCaptures = []
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )
        panel.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))

        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            Task { await self.clipboardMonitor.stop() }
            self.escCancelManager.isEnabled = false
            self.panel.onFocusLost = nil
            self.panel.onPillClicked = nil
            self.originalCapture = nil
            self.accumulatedCaptures = []
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
        }

        Logger.app.info("Capture view: overlay shown")

        // Capture selection in background
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        let capturedText = await selectionCapturer.capture(bundleIdentifier: bundleID, pid: pid)
        if let capturedText {
            let context = CapturedContext(text: capturedText, source: .selection)
            session?.captures = [context]
            originalCapture = context
            panel.updateCaptures([context])
        }
    }

    private func showPanelWithText(_ text: String) {
        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }

        let captures = session?.captures ?? []
        let turns = session?.conversationTurns ?? []

        panel.show(
            settings: settings,
            conversationTurns: turns,
            captures: captures,
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
            onSubmit: { [weak self] text in
                Task { await self?.clipboardMonitor.stop() }
                self?.escCancelManager.isEnabled = false
                self?.panel.onFocusLost = nil
                self?.panel.onPillClicked = nil
                self?.originalCapture = nil
                self?.accumulatedCaptures = []
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )
        panel.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))

        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            Task { await self.clipboardMonitor.stop() }
            self.escCancelManager.isEnabled = false
            self.panel.onFocusLost = nil
            self.panel.onPillClicked = nil
            self.originalCapture = nil
            self.accumulatedCaptures = []
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
        }

        // Insert text into the panel after it's shown
        panel.insertTextAtCursor(text)
    }

    private func showPanelMinimized(phase: CaptureViewModel.PillPhase) {
        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }

        panel.show(
            settings: settings,
            conversationTurns: [],
            captures: [],
            outputDestinations: settings.outputDestinations,
            audioRecorder: audioRecorder,
            onSubmit: { [weak self] text in
                Task { await self?.clipboardMonitor.stop() }
                self?.escCancelManager.isEnabled = false
                self?.panel.onFocusLost = nil
                self?.panel.onPillClicked = nil
                self?.originalCapture = nil
                self?.accumulatedCaptures = []
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )

        panel.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))

        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            Task { await self.clipboardMonitor.stop() }
            self.escCancelManager.isEnabled = false
            self.panel.onFocusLost = nil
            self.panel.onPillClicked = nil
            self.originalCapture = nil
            self.accumulatedCaptures = []
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
        }

        panel.minimize(phase: phase)
    }

    // MARK: - Collapse / Expand

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
        let newContexts = newCaptures.map { CapturedContext(text: $0, source: .clipboard) }
        accumulatedCaptures.append(contentsOf: newContexts)

        var allCaptures: [CapturedContext] = []
        if let original = originalCapture { allCaptures.append(original) }
        allCaptures.append(contentsOf: accumulatedCaptures)
        panel.updateCaptures(allCaptures)
        session?.captures = allCaptures
        panel.expand()
        escCancelManager.isEnabled = false
        Logger.app.info("Capture view: expanded from pill with \(self.accumulatedCaptures.count) clipboard captures")
    }

    /// Dismiss — keeps capture in history.
    func dismissOverlay() {
        Task { await clipboardMonitor.stop() }
        escCancelManager.isEnabled = false
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        panel.dismiss()
        session = nil
        originalCapture = nil
        accumulatedCaptures = []
        Logger.app.info("Capture view dismissed (capture preserved in history)")
    }

    /// Dismiss the panel if it's active (visible in any state).
    func dismissIfActive() {
        guard panel.isVisible else { return }
        dismissOverlay()
    }

    // MARK: - Cancel Capture

    /// Cancels the current capture and removes it from history.
    func cancelCapture() {
        if let conversationID = session?.conversationID,
           let conversation = transcriptionHistory.conversations.first(where: { $0.id == conversationID }) {
            transcriptionHistory.removeConversation(conversation)
            Logger.app.info("Capture cancelled and removed from history")
        }
        dismissOverlay()
    }

    // MARK: - Text Submission Pipeline

    private func submitText(_ text: String) {
        let pipelineSession = session ?? PipelineSession()
        let mode = settings.activeMode
        let captures = pipelineSession.captures
        let activeConversationID = pipelineSession.conversationID ?? UUID()
        let currentTurns = pipelineSession.conversationTurns
        let context = pipelineSession.followUpContext
        let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier
        let destinationID = overrides.resolvedDestinationID(for: mode)
        session = nil

        let destination = settings.outputDestination(for: destinationID)
        let useStreaming = destination.type == .outputPanel && mode.processingType == .bashScript

        Logger.app.info("Capture view: executing pipeline")

        if useStreaming {
            // --- Streaming path ---
            let parameterValues = self.overrides.resolvedParameterValues(for: mode)
            let streamResult = TextProcessingPipeline.runStreaming(
                mode: mode,
                text: text,
                captures: captures,
                followUpContext: context,
                conversationTurns: currentTurns,
                conversationID: activeConversationID,
                parameterValues: parameterValues
            )

            panel.startProcessing(inputText: text)
            recordingIndicator.hide()

            Task { @MainActor in
                var accumulated = ""
                do {
                    for try await chunk in streamResult.chunks {
                        accumulated += chunk
                        panel.updateStreamingOutput(accumulated)
                    }

                    panel.finishStreaming(outputText: accumulated)
                    panel.makeKeyIfVisible()

                    transcriptionHistory.recordTurn(
                        conversationID: activeConversationID,
                        input: text,
                        output: accumulated,
                        captures: captures,
                        modeID: mode.id,
                        modeName: mode.name,
                        hadExternalProcessing: streamResult.hadExternalProcessing
                    )

                    // Re-create session for follow-up
                    self.session = PipelineSession()
                    self.session?.conversationTurns = self.panel.currentTurns
                    self.session?.conversationID = activeConversationID
                    self.session?.followUpContext = accumulated
                    self.session?.previousActiveApp = pipelineSession.previousActiveApp

                    self.overrides.markPipelineCompleted()
                    Logger.app.info("Capture view: streaming complete")
                } catch {
                    streamResult.cancel()
                    if accumulated.isEmpty {
                        panel.showProcessingError(error.localizedDescription)
                    } else {
                        panel.finishStreaming(outputText: accumulated)
                    }
                    session = nil
                    Logger.app.error("Capture view streaming failed: \(error)")
                }
            }
        } else {
            // --- Non-streaming path ---
            if mode.processingType == .bashScript {
                panel.startProcessing(inputText: text)
            }

            Task { @MainActor in
                do {
                    let parameterValues = self.overrides.resolvedParameterValues(for: mode)
                    let result = try await TextProcessingPipeline.run(
                        mode: mode,
                        text: text,
                        captures: captures,
                        followUpContext: context,
                        conversationTurns: currentTurns,
                        conversationID: activeConversationID,
                        parameterValues: parameterValues
                    )
                    let processedText = result.text

                    if destination.type == .outputPanel {
                        recordingIndicator.hide()
                        if mode.processingType == .bashScript {
                            panel.finishProcessing(outputText: processedText)
                            panel.makeKeyIfVisible()
                        } else {
                            // No processing — route text directly to destination
                            panel.dismiss()
                            if let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: activeConversationID) {
                                try await action.execute(text: processedText)
                            }
                        }
                    } else {
                        panel.dismiss()
                        if let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: activeConversationID) {
                            try await action.execute(text: processedText)
                        }
                        recordingIndicator.update(phase: .success)
                        dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                    }

                    transcriptionHistory.recordTurn(
                        conversationID: activeConversationID,
                        input: text,
                        output: processedText,
                        captures: captures,
                        modeID: mode.id,
                        modeName: mode.name,
                        hadExternalProcessing: result.hadExternalProcessing
                    )

                    // Re-create session for follow-up if panel is still visible
                    if panel.isVisible && result.hadExternalProcessing {
                        self.session = PipelineSession()
                        self.session?.conversationTurns = self.panel.currentTurns
                        self.session?.conversationID = activeConversationID
                        self.session?.followUpContext = processedText
                        self.session?.previousActiveApp = pipelineSession.previousActiveApp
                    }

                    self.overrides.markPipelineCompleted()
                    Logger.app.info("Capture view: pipeline complete")
                } catch {
                    panel.showProcessingError(error.localizedDescription)
                    session = nil
                    Logger.app.error("Capture view pipeline failed: \(error)")
                }
            }
        }
    }

    private func dismissIndicatorAfterDelay(_ duration: Duration) {
        Task {
            try? await Task.sleep(for: duration)
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }
}
