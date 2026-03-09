import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class PushToTypeCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = PushToTypePanel()
    private let recordingIndicator: RecordingIndicatorPanel
    private let outputPanel: OutputPanelPanel
    private let selectionCapturer: SelectionCapturer
    private let clipboardMonitor: ClipboardMonitor
    private let escCancelManager: GlobalHotkeyManager
    private let transcriptionHistory: TranscriptionHistory
    private let overrides: ConversationOverrides

    /// Per-pipeline-run state. Non-nil while a pipeline is in progress or follow-up
    /// state has been captured from the output panel. Cleared on completion/error/cancel.
    var session: PipelineSession?

    /// The initial AX capture from when the session was opened. Set once per session.
    private var originalCapturedSelection: String?
    /// All Cmd+C captures accumulated across collapse/expand cycles.
    private var accumulatedCaptures: [String] = []

    /// Called when the push-to-type overlay is about to show.
    /// Used to dismiss the mode switcher overlay.
    var onWillStartInput: (() -> Void)?

    /// Whether the push-to-type panel is visible and can host a contextual mode switcher
    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    /// Whether a contextual mode switcher is currently showing inside the push-to-type panel
    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

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
    private static let errorIndicatorDuration: Duration = .seconds(10)
    /// Gap between the bottom of the output panel and the top of the push-to-type overlay
    private static let panelGap: CGFloat = 8
    private static let escapeKeyCode: CGKeyCode = 53

    init(
        settings: AppSettings,
        recordingIndicator: RecordingIndicatorPanel,
        outputPanel: OutputPanelPanel,
        selectionCapturer: SelectionCapturer,
        clipboardMonitor: ClipboardMonitor,
        escCancelManager: GlobalHotkeyManager,
        transcriptionHistory: TranscriptionHistory,
        overrides: ConversationOverrides
    ) {
        self.settings = settings
        self.recordingIndicator = recordingIndicator
        self.outputPanel = outputPanel
        self.selectionCapturer = selectionCapturer
        self.clipboardMonitor = clipboardMonitor
        self.escCancelManager = escCancelManager
        self.transcriptionHistory = transcriptionHistory
        self.overrides = overrides
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

    /// Registers the global Escape tap for dismissing the panel while collapsed.
    /// Starts disabled — enabled only when the panel collapses.
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
            // Expanded → collapse (preserve session)
            collapseOverlay()
        } else if panel.isVisible && panel.isMinimized {
            // Collapsed → expand (restore session)
            await expandFromCollapsed()
        } else {
            // Hidden → show
            onWillStartInput?()

            // If the output panel is visible, this is an implicit follow-up.
            // Expand the output panel instead of showing push-to-type —
            // the output panel's inline text editor handles typed follow-up.
            if let followUp = outputPanel.readFollowUpState() {
                settings.activeModeID = followUp.modeID
                outputPanel.expand()
                outputPanel.makeKeyIfVisible()
                return
            }

            overrides.clearIfCompletedPipeline()
            if session == nil {
                session = PipelineSession()
            }
            await showOverlay()
        }
    }

    private func showOverlay() async {
        // Remember the frontmost app for focus restoration, but show the panel
        // immediately — don't block on AX selection capture (it can be slow or
        // fail for apps like Alacritty). The user can gather context later via
        // collapse → Cmd+C → expand.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        session?.previousActiveApp = frontmostApp

        // When the output panel is visible, position below it and skip duplicate
        // conversation turns (the output panel already shows them).
        let isFollowUp = session?.isFollowUpFromVisibleOutputPanel ?? false
        let topOffset = isFollowUp
            ? outputPanel.currentPanelHeight + Self.panelGap
            : 0
        let overlayTurns = isFollowUp ? [] : (session?.conversationTurns ?? [])

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
            capturedSelection: nil,
            topOffset: topOffset,
            onSubmit: { [weak self] text in
                // Clean up collapse state without nilling session — submitText needs it
                Task { await self?.clipboardMonitor.stop() }
                self?.escCancelManager.isEnabled = false
                self?.panel.onFocusLost = nil
                self?.panel.onPillClicked = nil
                self?.originalCapturedSelection = nil
                self?.accumulatedCaptures = []
                self?.submitText(text)
            },
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )
        panel.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))

        // Wire destination hotkeys: submit text directly to a specific destination
        panel.setDestinationSubmitHandler { [weak self] text, destinationID in
            guard let self else { return }
            Task { await self.clipboardMonitor.stop() }
            self.escCancelManager.isEnabled = false
            self.panel.onFocusLost = nil
            self.panel.onPillClicked = nil
            self.originalCapturedSelection = nil
            self.accumulatedCaptures = []
            self.overrides.destinationOverride = destinationID
            self.submitText(text)
            self.panel.hide()
        }

        Logger.app.info("Push-to-type: overlay shown")

        // Capture selection in the background — update panel and session if it succeeds
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        let captured = await selectionCapturer.capture(bundleIdentifier: bundleID, pid: pid)
        if let captured {
            session?.capturedSelection = captured
            originalCapturedSelection = captured
            panel.updateCapturedSelection(captured)
        }
    }

    // MARK: - Collapse / Expand

    private func collapseOverlay() {
        panel.minimize()
        // Start clipboard monitoring so Cmd+C captures are gathered while collapsed
        Task {
            await clipboardMonitor.start { [weak self] _ in
                self?.panel.signalClipboardCapture()
            }
        }
        escCancelManager.isEnabled = true
        Logger.app.info("Push-to-type: collapsed to pill")
    }

    private func expandFromCollapsed() async {
        // Stop clipboard monitor and gather new captures
        let newCaptures = await clipboardMonitor.stop()
        accumulatedCaptures.append(contentsOf: newCaptures)

        // Merge all captures (original AX capture + all accumulated Cmd+C captures)
        let merged = RecordingCoordinator.mergeCaptures(
            initial: originalCapturedSelection,
            midRecording: accumulatedCaptures
        )
        panel.updateCapturedSelection(merged)
        // Also update session so submitText gets the merged selection
        session?.capturedSelection = merged
        panel.expand()
        escCancelManager.isEnabled = false
        Logger.app.info("Push-to-type: expanded from pill with \(self.accumulatedCaptures.count) clipboard captures")
    }

    /// Full teardown — destroys the session, stops monitoring, hides panel.
    func dismissOverlay() {
        Task { await clipboardMonitor.stop() }
        escCancelManager.isEnabled = false
        panel.onFocusLost = nil
        panel.onPillClicked = nil
        panel.hide()
        session = nil
        originalCapturedSelection = nil
        accumulatedCaptures = []
        outputPanel.unlockFollowUp()
        Logger.app.info("Push-to-type: overlay dismissed")
    }

    /// Dismiss the PTT panel if it's active (visible in any state).
    /// Called when push-to-talk recording starts to avoid conflicts.
    func dismissIfActive() {
        guard panel.isVisible else { return }
        dismissOverlay()
    }

    // MARK: - Text Submission Pipeline

    private func submitText(_ text: String) {
        // Consume session state into locals for use throughout the pipeline
        let pipelineSession = session ?? PipelineSession()
        let mode = settings.activeMode
        let selection = pipelineSession.capturedSelection
        let activeConversationID = pipelineSession.conversationID ?? UUID()
        let currentTurns = pipelineSession.conversationTurns
        let context = pipelineSession.followUpContext
        let wasFollowUpFromOutputPanel = pipelineSession.isFollowUpFromVisibleOutputPanel
        let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier
        let destinationID = overrides.resolvedDestinationID(for: mode)
        session = nil

        let destination = settings.outputDestination(for: destinationID)
        let useStreaming = destination.type == .outputPanel && mode.processingType == .bashScript

        if wasFollowUpFromOutputPanel {
            // Output panel pill shows animated dots during processing
            outputPanel.startProcessing(inputText: text)
        }
        Logger.app.info("Push-to-type: executing pipeline")

        if useStreaming {
            // --- Streaming path ---
            let parameterValues = self.overrides.resolvedParameterValues(for: mode)
            let streamResult = TextProcessingPipeline.runStreaming(
                mode: mode,
                text: text,
                capturedSelection: selection,
                followUpContext: context,
                conversationTurns: currentTurns,
                conversationID: activeConversationID,
                parameterValues: parameterValues
            )

            if wasFollowUpFromOutputPanel {
                outputPanel.expand()
            } else {
                outputPanel.show(
                    inputText: text,
                    text: "",
                    capturedSelection: selection,
                    conversationTurns: currentTurns,
                    outputDestinations: settings.outputDestinations,
                    targetAppPID: targetAppPID,
                    modeID: mode.id,
                    conversationID: activeConversationID,
                    canFollowUp: true
                )
                outputPanel.setProcessing(true)
            }
            recordingIndicator.hide()

            Task { @MainActor in
                var accumulated = ""
                do {
                    for try await chunk in streamResult.chunks {
                        accumulated += chunk
                        outputPanel.updateStreamingOutput(accumulated)
                    }

                    if wasFollowUpFromOutputPanel {
                        outputPanel.finishStreaming(outputText: accumulated)
                        outputPanel.unlockFollowUp()
                        outputPanel.makeKeyIfVisible()
                    } else {
                        outputPanel.finishStreaming(outputText: accumulated)
                    }

                    transcriptionHistory.recordTurn(
                        conversationID: activeConversationID,
                        input: text,
                        output: accumulated,
                        capturedSelection: selection,
                        modeID: mode.id,
                        modeName: mode.name,
                        hadExternalProcessing: streamResult.hadExternalProcessing
                    )

                    self.overrides.markPipelineCompleted()
                    Logger.app.info("Push-to-type: streaming complete")
                } catch {
                    streamResult.cancel()
                    if wasFollowUpFromOutputPanel {
                        if accumulated.isEmpty {
                            outputPanel.showProcessingError(error.localizedDescription)
                        } else {
                            outputPanel.finishStreaming(outputText: accumulated)
                        }
                    }
                    outputPanel.unlockFollowUp()
                    session = nil
                    Logger.app.error("Push-to-type streaming failed: \(error)")
                }
            }
        } else {
            // --- Non-streaming path ---
            if !wasFollowUpFromOutputPanel {
                recordingIndicator.show()
                recordingIndicator.update(phase: .processing)
                recordingIndicator.updateParameterLabels(overrides.resolvedParameterLabels(for: settings.activeMode))
            }

            Task { @MainActor in
                do {
                    let parameterValues = self.overrides.resolvedParameterValues(for: mode)
                    let result = try await TextProcessingPipeline.run(
                        mode: mode,
                        text: text,
                        capturedSelection: selection,
                        followUpContext: context,
                        conversationTurns: currentTurns,
                        conversationID: activeConversationID,
                        parameterValues: parameterValues
                    )
                    let processedText = result.text

                    if destination.type == .outputPanel {
                        recordingIndicator.hide()
                        if wasFollowUpFromOutputPanel {
                            outputPanel.finishProcessing(outputText: processedText)
                            outputPanel.unlockFollowUp()
                            outputPanel.makeKeyIfVisible()
                        } else {
                            outputPanel.show(
                                inputText: text,
                                text: processedText,
                                capturedSelection: selection,
                                conversationTurns: currentTurns,
                                outputDestinations: settings.outputDestinations,
                                targetAppPID: targetAppPID,
                                modeID: mode.id,
                                conversationID: activeConversationID,
                                canFollowUp: result.hadExternalProcessing
                            )
                        }
                    } else {
                        outputPanel.unlockFollowUp()
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
                        capturedSelection: selection,
                        modeID: mode.id,
                        modeName: mode.name,
                        hadExternalProcessing: result.hadExternalProcessing
                    )

                    self.overrides.markPipelineCompleted()
                    Logger.app.info("Push-to-type: complete")
                } catch {
                    if wasFollowUpFromOutputPanel {
                        outputPanel.showProcessingError(error.localizedDescription)
                    }
                    outputPanel.unlockFollowUp()
                    session = nil
                    if !wasFollowUpFromOutputPanel {
                        recordingIndicator.update(phase: .error, message: error.localizedDescription)
                        dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                    }
                    Logger.app.error("Push-to-type failed: \(error)")
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
