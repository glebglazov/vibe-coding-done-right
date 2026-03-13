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
    private var session: PipelineSession?

    /// The initial AX capture from when the session was opened.
    private var originalCapture: CapturedContext?
    /// All Cmd+C captures accumulated across collapse/expand cycles.
    private var accumulatedCaptures: [CapturedContext] = []

    /// The in-flight pill phase reset Task. Cancelled when a new recording
    /// notification arrives to prevent stale .idle overwriting .recording.
    private var pillResetTask: Task<Void, Never>?

    /// The in-flight auto-dismiss Task. Cancelled when a new recording starts
    /// to prevent an orphaned task from dismissing the new recording's panel.
    private var autoDismissTask: Task<Void, Never>?

    /// The in-flight indicator dismiss Task. Stored so it can be cancelled
    /// when a new recording cycle starts, preventing a stale hide from
    /// dismissing the new recording's indicator.
    private var dismissIndicatorTask: Task<Void, Never>?

    /// Called when the capture overlay is about to show.
    var onWillStartInput: (() -> Void)?

    /// Whether the capture panel is visible and can host a contextual mode switcher
    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    /// Whether a contextual mode switcher is currently showing inside the capture panel
    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

    /// Whether the capture panel is visible in any state
    var isPanelVisible: Bool { panel.isVisible }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
    }

    func hideModeSwitcher() {
        panel.hideModeSwitcher()
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

    // MARK: - Recording Event Handlers (called via closures from RecordingCoordinator)

    /// Called when recording starts. Handles panel lock and pill display.
    func handleRecordingStarted(isFollowUp: Bool) {
        if isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingStarted(isFollowUp=true) but panel is not visible — RC/CC disagree on follow-up status")
        }
        pillResetTask?.cancel()
        autoDismissTask?.cancel()
        dismissIndicatorTask?.cancel()
        if isFollowUp && panel.isVisible {
            panel.lockForFollowUp()
            panel.setPhase(.recording)
        } else if !isFollowUp && !settings.activeMode.quickAction {
            // Normal mode, fresh recording: show pill
            showPanelMinimized(phase: .recording)
        }
        // Quick action fresh recording: RC shows its own indicator, CC does nothing
    }

    /// Called when transcription is in progress.
    func handleTranscribing() {
        panel.setPhase(.processing)
    }

    /// Called when transcription completed with text.
    func handleRecordingComplete(result: RecordingResult) {
        if result.isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingComplete(isFollowUp=true) but panel is not visible")
        }
        panel.unlockFollowUp()

        // Apply destination override if recording had one
        if let overrideID = result.destinationOverrideID {
            overrides.destinationOverride = overrideID
        }

        let mode = settings.activeMode
        let isQuickAction = !result.isFollowUp && (mode.quickAction || result.hadDestinationOverride)

        if isQuickAction {
            executeQuickAction(result: result, mode: mode)
        } else {
            populateWithTranscription(result: result)
        }
    }

    /// Called when transcription produced empty text.
    func handleTranscriptionFailed(isFollowUp: Bool) {
        panel.unlockFollowUp()
        if isFollowUp && panel.isVisible {
            // Panel was already showing — flash error on pill
            notifyTranscriptionFailed()
        } else if panel.isVisible {
            // Fresh recording showed a pill — flash error then dismiss
            notifyTranscriptionFailed()
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillErrorDisplayDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if !isFollowUp {
            // Quick action mode: RC showed the recording indicator, show error there
            recordingIndicator.update(phase: .error, message: "No speech detected")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
        }
    }

    /// Called when recording was cancelled.
    func handleRecordingCancelled(wasFollowUp: Bool, wasFreshPill: Bool) {
        panel.unlockFollowUp()
        if panel.isVisible && wasFreshPill {
            notifyCancelled()
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if panel.isVisible && wasFollowUp {
            notifyCancelled()
        }
        // Quick action mode: RC already showed cancelled on indicator
    }

    /// Called when recording failed to start.
    func handleRecordingFailed(message: String) {
        panel.unlockFollowUp()
        panel.setPhase(.idle)
    }

    // MARK: - Pill Notification Helpers

    /// Briefly shows an error state on the pill, then returns to idle.
    private func notifyTranscriptionFailed() {
        panel.setPhase(.error)
        if panel.isVisible {
            pillResetTask?.cancel()
            pillResetTask = Task {
                try? await Task.sleep(for: Self.pillErrorDisplayDuration)
                guard !Task.isCancelled else { return }
                panel.setPhase(.idle)
            }
        }
    }

    /// Briefly flashes the cancelled icon on the pill, then returns to idle.
    private func notifyCancelled() {
        if panel.isVisible {
            panel.setPhase(.cancelled)
            if !panel.isMinimized { panel.minimize() }
            pillResetTask?.cancel()
            pillResetTask = Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                guard !Task.isCancelled else { return }
                panel.setPhase(.idle)
            }
        }
    }

    /// Briefly flashes the success icon on the pill, then returns to idle.
    private func notifySuccess() {
        if panel.isVisible {
            panel.setPhase(.success)
            if !panel.isMinimized { panel.minimize() }
            pillResetTask?.cancel()
            pillResetTask = Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                guard !Task.isCancelled else { return }
                panel.setPhase(.idle)
            }
        }
    }

    // MARK: - Quick Action Pipeline

    /// Executes the quick action pipeline: process text and route to destination.
    /// Called when a recording completes in quick action mode.
    private func executeQuickAction(result: RecordingResult, mode: Mode) {
        let captures = result.captures
        let previousActiveApp = result.previousActiveApp
        let conversationID = session?.conversationID ?? UUID()
        let currentTurns = session?.conversationTurns ?? []
        let followUpContext = session?.followUpContext
        let targetAppPID = previousActiveApp?.processIdentifier
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)

        let pipelineContext = SubmissionPipeline.Context(
            text: result.text,
            mode: mode,
            captures: captures,
            followUpContext: followUpContext,
            conversationTurns: currentTurns,
            conversationID: conversationID,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            destination: destination,
            targetAppPID: targetAppPID
        )

        Task { @MainActor in
            do {
                let pipelineResult = try await SubmissionPipeline.run(context: pipelineContext)

                if destination.type == .outputPanel {
                    let turn = ConversationTurn(input: result.text, output: pipelineResult.processedText, captures: captures)
                    panel.dismiss()
                    session = PipelineSession()
                    session?.previousActiveApp = previousActiveApp
                    session?.captures = captures
                    session?.conversationID = conversationID
                    session?.conversationTurns = [turn]
                    session?.followUpContext = pipelineResult.processedText
                    showPanelWithText("")
                    if pipelineResult.hadExternalProcessing {
                        panel.setProcessedByModeName(mode.name)
                    }
                    recordingIndicator.hide()
                } else {
                    let panelWasVisible = panel.isVisible
                    panel.dismiss()
                    // Action already executed by SubmissionPipeline.run()
                    if !panelWasVisible {
                        recordingIndicator.update(phase: .success)
                        dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                    }
                }

                SubmissionPipeline.recordTurn(
                    history: transcriptionHistory,
                    conversationID: conversationID,
                    input: result.text,
                    output: pipelineResult.processedText,
                    captures: captures,
                    modeID: mode.id,
                    modeName: mode.name,
                    hadExternalProcessing: pipelineResult.hadExternalProcessing
                )

                overrides.markPipelineCompleted()
                Logger.app.info("Quick action pipeline complete")
            } catch {
                recordingIndicator.update(phase: .error, message: error.localizedDescription)
                dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
                Logger.app.error("Quick action pipeline failed: \(error)")
            }
        }
    }

    // MARK: - Populate With Transcription

    /// Shows the Capture View with transcribed text after recording completes (non-quick-action).
    private func populateWithTranscription(result: RecordingResult) {
        if session == nil {
            session = PipelineSession()
            session?.previousActiveApp = result.previousActiveApp
        }
        // Assign conversationID lazily — the session may have been created
        // by toggleOverlay() without one (push-to-type opens the panel
        // before any recording happens).
        if session?.conversationID == nil {
            session?.conversationID = UUID()
        }
        guard let activeSession = session, let currentConversationID = activeSession.conversationID else {
            Logger.app.error("populateWithTranscription: session unexpectedly nil")
            return
        }

        let newCaptures = result.captures
        let hasNewCapture = !newCaptures.isEmpty

        if panel.isVisible {
            panel.setPhase(.idle)

            // If the panel only has the default empty segment (from showPanelMinimized
            // during recording), replace it rather than appending after it — otherwise
            // the leading empty segment causes a zero-length editable region and the
            // cursor lands on the tiny-font separator, appearing "cut in half".
            let hasOnlyEmptySegment = panel.segmentCount == 1
                && panel.fullText.isEmpty && panel.allCaptures.isEmpty

            if hasOnlyEmptySegment {
                if hasNewCapture {
                    let capture = newCaptures[0]
                    panel.setSegments([InputSegment(text: result.text, capture: capture)])
                } else {
                    panel.setSegments([InputSegment(text: result.text)])
                }
            } else if hasNewCapture {
                // Follow-up with new captured context -> new segment at end (chronological order)
                let capture = newCaptures[0]
                let segment = InputSegment(text: result.text, capture: capture)
                panel.appendSegment(segment)
            } else {
                // Follow-up without new capture -> append to active segment
                panel.appendTextToActiveSegment(result.text)
            }

            // Merge captures into session
            session?.captures.append(contentsOf: newCaptures)
        } else {
            session?.captures = newCaptures
            let segments: [InputSegment]
            if let capture = newCaptures.first {
                segments = [InputSegment(text: result.text, capture: capture)]
            } else {
                segments = [InputSegment(text: result.text)]
            }
            showPanelWithSegments(segments)
        }

        panel.expand()
        recordingIndicator.hide()

        if session?.hasUnsubmittedDraft == true {
            let fullText = panel.fullText
            transcriptionHistory.updateLastTurn(
                conversationID: currentConversationID,
                input: fullText,
                output: fullText,
                captures: session?.captures ?? [],
                modeID: settings.activeModeID,
                modeName: settings.activeMode.name,
                hadExternalProcessing: false
            )
        } else {
            transcriptionHistory.recordTurn(
                conversationID: currentConversationID,
                input: result.text,
                output: result.text,
                captures: newCaptures,
                modeID: settings.activeModeID,
                modeName: settings.activeMode.name,
                hadExternalProcessing: false
            )
            session?.hasUnsubmittedDraft = true
        }

        overrides.markPipelineCompleted()
        Logger.app.info("Pipeline: handed to capture view")
    }

    private func showPanelWithSegments(_ segments: [InputSegment]) {
        let turns = session?.conversationTurns ?? []
        configurePanelAndShow(conversationTurns: turns, segments: segments)
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

        // Fresh segment for new input (no need to reconstruct old segments)
        configurePanelAndShow(conversationTurns: turns, segments: [InputSegment()])
        if conversation.hadExternalProcessing {
            panel.setProcessedByModeName(conversation.modeName)
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

    // MARK: - Panel Configuration

    /// Wires standard panel callbacks and calls panel.show().
    /// All show methods delegate here, passing only what differs.
    private func configurePanelAndShow(
        conversationTurns: [ConversationTurn] = [],
        captures: [CapturedContext] = [],
        segments: [InputSegment]? = nil
    ) {
        panel.onFocusLost = { [weak self] in
            self?.collapseOverlay()
        }
        panel.onPillClicked = { [weak self] in
            Task { @MainActor in
                await self?.expandFromCollapsed()
            }
        }

        // Build segments from captures if no explicit segments provided
        let resolvedSegments: [InputSegment]
        if let segments {
            resolvedSegments = segments
        } else if !captures.isEmpty {
            if captures.count == 1 {
                resolvedSegments = [InputSegment(capture: captures.first)]
            } else {
                resolvedSegments = [InputSegment(capture: captures.first)] + captures.dropFirst().map { InputSegment(capture: $0) }
            }
        } else {
            resolvedSegments = [InputSegment()]
        }

        panel.show(
            settings: settings,
            overrides: overrides,
            conversationTurns: conversationTurns,
            segments: resolvedSegments,
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

        // Capture selection BEFORE showing panel — the panel steals AX focus,
        // so captureViaAccessibility would read from the panel's TextEditor
        // instead of the original app, and Cmd+C fallback would target the panel.
        let bundleID = frontmostApp?.bundleIdentifier
        let pid = frontmostApp?.processIdentifier
        let capturedText = await selectionCapturer.capture(bundleIdentifier: bundleID, pid: pid)

        let overlayTurns = session?.conversationTurns ?? []

        if let capturedText {
            let context = CapturedContext(text: capturedText, source: .selection)
            let segment = InputSegment(capture: context)
            session?.captures = [context]
            originalCapture = context
            configurePanelAndShow(conversationTurns: overlayTurns, segments: [segment])
            panel.signalClipboardCapture()
        } else {
            configurePanelAndShow(conversationTurns: overlayTurns)
        }

        Logger.app.info("Capture view: overlay shown")
    }

    private func showPanelWithText(_ text: String) {
        let captures = session?.captures ?? []
        let turns = session?.conversationTurns ?? []
        let segments: [InputSegment]
        if captures.count == 1 {
            segments = [InputSegment(text: text, capture: captures.first)]
        } else if captures.count > 1 {
            var segs = [InputSegment(text: text, capture: captures.first)]
            for capture in captures.dropFirst() {
                segs.append(InputSegment(capture: capture))
            }
            segments = segs
        } else {
            segments = [InputSegment(text: text)]
        }
        configurePanelAndShow(conversationTurns: turns, segments: segments)
    }

    private func showPanelMinimized(phase: CaptureViewModel.CapturePhase) {
        configurePanelAndShow()
        panel.setPhase(phase)
        panel.minimize()
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

        if !newCaptures.isEmpty {
            for capturedText in newCaptures {
                let context = CapturedContext(text: capturedText, source: .clipboard)
                accumulatedCaptures.append(context)
                // Insert a new segment after the active segment
                let segment = InputSegment(capture: context)
                panel.insertSegment(segment)
            }
            // Update session captures
            session?.captures = panel.allCaptures
        }

        panel.expand()
        escCancelManager.isEnabled = false
        Logger.app.info("Capture view: expanded from pill with \(newCaptures.count) clipboard captures")
    }

    /// Dismiss — keeps capture in history.
    func dismissOverlay() {
        Task { await clipboardMonitor.stop() }
        escCancelManager.isEnabled = false
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
        let hasUnsubmittedDraft = pipelineSession.hasUnsubmittedDraft
        let currentTurns = pipelineSession.conversationTurns
        let followUpContext = pipelineSession.followUpContext
        let targetAppPID = pipelineSession.previousActiveApp?.processIdentifier
        let destinationID = overrides.resolvedDestinationID(for: mode)
        session = nil

        let destination = settings.outputDestination(for: destinationID)
        let useStreaming = destination.type == .outputPanel && mode.processingType == .bashScript

        let pipelineContext = SubmissionPipeline.Context(
            text: text,
            mode: mode,
            captures: [],  // captures are already inline in text via <capture-N> tags
            followUpContext: followUpContext,
            conversationTurns: currentTurns,
            conversationID: activeConversationID,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            destination: destination,
            targetAppPID: targetAppPID
        )

        Logger.app.info("Capture view: executing pipeline")

        if useStreaming {
            let streamResult = SubmissionPipeline.runStreaming(context: pipelineContext)
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
                    if streamResult.hadExternalProcessing {
                        panel.setProcessedByModeName(mode.name)
                    }
                    panel.makeKeyIfVisible()

                    if hasUnsubmittedDraft {
                        SubmissionPipeline.updateLastTurn(
                            history: transcriptionHistory,
                            conversationID: activeConversationID,
                            input: text, output: accumulated, captures: captures,
                            modeID: mode.id, modeName: mode.name,
                            hadExternalProcessing: streamResult.hadExternalProcessing
                        )
                    } else {
                        SubmissionPipeline.recordTurn(
                            history: transcriptionHistory,
                            conversationID: activeConversationID,
                            input: text, output: accumulated, captures: captures,
                            modeID: mode.id, modeName: mode.name,
                            hadExternalProcessing: streamResult.hadExternalProcessing
                        )
                    }

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
            if mode.processingType == .bashScript {
                panel.startProcessing(inputText: text)
            }

            Task { @MainActor in
                do {
                    let result = try await SubmissionPipeline.run(context: pipelineContext)

                    if destination.type == .outputPanel {
                        recordingIndicator.hide()
                        if mode.processingType == .bashScript {
                            panel.finishProcessing(outputText: result.processedText)
                            if result.hadExternalProcessing {
                                panel.setProcessedByModeName(mode.name)
                            }
                            panel.makeKeyIfVisible()
                        } else {
                            panel.dismiss()
                        }
                    } else {
                        panel.dismiss()
                        // Action already executed by SubmissionPipeline.run()
                        recordingIndicator.update(phase: .success)
                        dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                    }

                    if hasUnsubmittedDraft {
                        SubmissionPipeline.updateLastTurn(
                            history: transcriptionHistory,
                            conversationID: activeConversationID,
                            input: text, output: result.processedText, captures: captures,
                            modeID: mode.id, modeName: mode.name,
                            hadExternalProcessing: result.hadExternalProcessing
                        )
                    } else {
                        SubmissionPipeline.recordTurn(
                            history: transcriptionHistory,
                            conversationID: activeConversationID,
                            input: text, output: result.processedText, captures: captures,
                            modeID: mode.id, modeName: mode.name,
                            hadExternalProcessing: result.hadExternalProcessing
                        )
                    }

                    if panel.isVisible && result.hadExternalProcessing {
                        self.session = PipelineSession()
                        self.session?.conversationTurns = self.panel.currentTurns
                        self.session?.conversationID = activeConversationID
                        self.session?.followUpContext = result.processedText
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
        dismissIndicatorTask?.cancel()
        dismissIndicatorTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            let phase = recordingIndicator.currentPhase
            if phase == .success || phase == .error {
                recordingIndicator.hide()
            }
        }
    }
}
