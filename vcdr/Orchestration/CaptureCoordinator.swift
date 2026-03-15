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

    private var session: PipelineSession?

    private var originalCapture: CapturedContext?
    private var accumulatedCaptures: [CapturedContext] = []

    private var pillResetTask: Task<Void, Never>?

    private var autoDismissTask: Task<Void, Never>?

    private var dismissIndicatorTask: Task<Void, Never>?

    private var expandTimerTask: Task<Void, Never>?

    var onWillStartInput: (() -> Void)?

    var isModeSwitcherHostVisible: Bool { panel.isVisible && !panel.isMinimized }

    var isModeSwitcherVisible: Bool { panel.isModeSwitcherVisible }

    var isPanelVisible: Bool { panel.isVisible }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        panel.showModeSwitcher(viewModel: viewModel)
    }

    func hideModeSwitcher() {
        panel.hideModeSwitcher()
    }

    private static let successIndicatorDuration: Duration = .seconds(2)
    private static let pillErrorDisplayDuration: Duration = .seconds(1.5)
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
            showPanelMinimized(phase: .recording)
        }
    }

    func handleTranscribing() {
        panel.setPhase(.processing)
    }

    func handleRecordingComplete(result: RecordingResult) {
        if result.isFollowUp && !panel.isVisible {
            Logger.consistency.warning("handleRecordingComplete(isFollowUp=true) but panel is not visible")
        }
        panel.unlockFollowUp()

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

    func handleTranscriptionFailed(isFollowUp: Bool) {
        panel.unlockFollowUp()
        if isFollowUp && panel.isVisible {
            flashPill(phase: .error, duration: Self.pillErrorDisplayDuration)
        } else if panel.isVisible {
            flashPill(phase: .error, duration: Self.pillErrorDisplayDuration)
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillErrorDisplayDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if !isFollowUp {
            recordingIndicator.update(phase: .error, message: "No speech detected")
            dismissIndicatorAfterDelay(Self.errorIndicatorDuration)
        }
    }

    func handleRecordingCancelled(wasFollowUp: Bool, wasFreshPill: Bool) {
        panel.unlockFollowUp()
        if panel.isVisible && wasFreshPill {
            flashPill(phase: .cancelled, shouldMinimize: true, duration: Self.pillFlashDuration)
            autoDismissTask?.cancel()
            autoDismissTask = Task {
                try? await Task.sleep(for: Self.pillFlashDuration)
                guard !Task.isCancelled else { return }
                self.cancelCapture()
            }
        } else if panel.isVisible && wasFollowUp {
            flashPill(phase: .cancelled, shouldMinimize: true, duration: Self.pillFlashDuration)
        }
    }

    func handleRecordingFailed(message: String) {
        panel.unlockFollowUp()
        panel.setPhase(.idle)
    }

    private func flashPill(
        phase: CaptureViewModel.CapturePhase,
        shouldMinimize: Bool = false,
        duration: Duration
    ) {
        guard panel.isVisible else { return }
        panel.setPhase(phase)
        if shouldMinimize && !panel.isMinimized { panel.minimize() }
        pillResetTask?.cancel()
        pillResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            panel.setPhase(.idle)
        }
    }

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
                    let segments: [InputSegment]
                    if captures.isEmpty {
                        segments = [InputSegment()]
                    } else {
                        segments = [InputSegment(capture: captures.first)]
                            + captures.dropFirst().map { InputSegment(capture: $0) }
                    }
                    configurePanelAndShow(conversationTurns: [turn], segments: segments)
                    if pipelineResult.hadExternalProcessing {
                        panel.setProcessedByModeName(mode.name)
                    }
                    recordingIndicator.hide()
                } else {
                    let panelWasVisible = panel.isVisible
                    panel.dismiss()
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

    private func populateWithTranscription(result: RecordingResult) {
        if session == nil {
            session = PipelineSession()
            session?.previousActiveApp = result.previousActiveApp
        }
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
                let capture = newCaptures[0]
                let segment = InputSegment(text: result.text, capture: capture)
                panel.appendSegment(segment)
            } else {
                panel.appendTextToActiveSegment(result.text)
            }

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
            recordOrUpdateHistory(
                hasUnsubmittedDraft: true,
                conversationID: currentConversationID,
                input: fullText, output: fullText,
                captures: session?.captures ?? [],
                mode: settings.activeMode, hadExternalProcessing: false
            )
        } else {
            recordOrUpdateHistory(
                hasUnsubmittedDraft: false,
                conversationID: currentConversationID,
                input: result.text, output: result.text,
                captures: newCaptures,
                mode: settings.activeMode, hadExternalProcessing: false
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

    private func rewirePanelCallbacks() {
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

    private func configurePanelAndShow(
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

    private func showPanelMinimized(phase: CaptureViewModel.CapturePhase) {
        configurePanelAndShow()
        panel.setPhase(phase)
        panel.minimize()
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

    private struct SubmissionSnapshot {
        let pipelineContext: SubmissionPipeline.Context
        let mode: Mode
        let captures: [CapturedContext]
        let hasUnsubmittedDraft: Bool
        let conversationID: UUID
        let previousActiveApp: NSRunningApplication?
        let useStreaming: Bool
        let destination: OutputDestination
    }

    private func captureSubmissionSnapshot(text: String) -> SubmissionSnapshot {
        let pipelineSession = session ?? PipelineSession()
        let mode = settings.activeMode
        let conversationID = pipelineSession.conversationID ?? UUID()
        let destinationID = overrides.resolvedDestinationID(for: mode)
        let destination = settings.outputDestination(for: destinationID)

        let pipelineContext = SubmissionPipeline.Context(
            text: text,
            mode: mode,
            captures: [],  // captures are already inline in text via <capture-N> tags
            followUpContext: pipelineSession.followUpContext,
            conversationTurns: pipelineSession.conversationTurns,
            conversationID: conversationID,
            parameterValues: overrides.resolvedParameterValues(for: mode),
            destination: destination,
            targetAppPID: pipelineSession.previousActiveApp?.processIdentifier
        )

        return SubmissionSnapshot(
            pipelineContext: pipelineContext,
            mode: mode,
            captures: pipelineSession.captures,
            hasUnsubmittedDraft: pipelineSession.hasUnsubmittedDraft,
            conversationID: conversationID,
            previousActiveApp: pipelineSession.previousActiveApp,
            useStreaming: destination.type == .outputPanel && mode.processingType == .bashScript,
            destination: destination
        )
    }

    private func submitText(_ text: String) {
        let snapshot = captureSubmissionSnapshot(text: text)
        session = nil

        Logger.app.info("Capture view: executing pipeline")

        if snapshot.useStreaming {
            executeStreamingSubmission(snapshot, text: text)
        } else {
            executeNonStreamingSubmission(snapshot, text: text)
        }
    }

    private func executeStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        let streamResult = SubmissionPipeline.runStreaming(context: snapshot.pipelineContext)
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
                    panel.setProcessedByModeName(snapshot.mode.name)
                }
                panel.makeKeyIfVisible()

                recordOrUpdateHistory(
                    hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
                    conversationID: snapshot.conversationID,
                    input: text, output: accumulated, captures: snapshot.captures,
                    mode: snapshot.mode, hadExternalProcessing: streamResult.hadExternalProcessing
                )
                rebuildSessionForFollowUp(
                    conversationID: snapshot.conversationID,
                    followUpContext: accumulated,
                    previousActiveApp: snapshot.previousActiveApp
                )
                self.overrides.markPipelineCompleted()
                self.rewirePanelCallbacks()
                Logger.app.info("Capture view: streaming complete")
            } catch {
                streamResult.cancel()
                if accumulated.isEmpty {
                    panel.showProcessingError(error.localizedDescription)
                } else {
                    panel.finishStreaming(outputText: accumulated)
                }
                if panel.isVisible {
                    self.rewirePanelCallbacks()
                }
                session = nil
                Logger.app.error("Capture view streaming failed: \(error)")
            }
        }
    }

    private func executeNonStreamingSubmission(_ snapshot: SubmissionSnapshot, text: String) {
        if snapshot.mode.processingType == .bashScript {
            panel.startProcessing(inputText: text)
        }

        Task { @MainActor in
            do {
                let result = try await SubmissionPipeline.run(context: snapshot.pipelineContext)

                if snapshot.destination.type == .outputPanel {
                    recordingIndicator.hide()
                    if snapshot.mode.processingType == .bashScript {
                        panel.finishProcessing(outputText: result.processedText)
                        if result.hadExternalProcessing {
                            panel.setProcessedByModeName(snapshot.mode.name)
                        }
                        panel.makeKeyIfVisible()
                    } else {
                        panel.dismiss()
                    }
                } else {
                    panel.dismiss()
                    recordingIndicator.update(phase: .success)
                    dismissIndicatorAfterDelay(Self.successIndicatorDuration)
                }

                recordOrUpdateHistory(
                    hasUnsubmittedDraft: snapshot.hasUnsubmittedDraft,
                    conversationID: snapshot.conversationID,
                    input: text, output: result.processedText, captures: snapshot.captures,
                    mode: snapshot.mode, hadExternalProcessing: result.hadExternalProcessing
                )

                if panel.isVisible && result.hadExternalProcessing {
                    rebuildSessionForFollowUp(
                        conversationID: snapshot.conversationID,
                        followUpContext: result.processedText,
                        previousActiveApp: snapshot.previousActiveApp
                    )
                }

                self.overrides.markPipelineCompleted()
                if panel.isVisible {
                    self.rewirePanelCallbacks()
                }
                Logger.app.info("Capture view: pipeline complete")
            } catch {
                panel.showProcessingError(error.localizedDescription)
                if panel.isVisible {
                    self.rewirePanelCallbacks()
                }
                session = nil
                Logger.app.error("Capture view pipeline failed: \(error)")
            }
        }
    }

    private func recordOrUpdateHistory(
        hasUnsubmittedDraft: Bool,
        conversationID: UUID,
        input: String,
        output: String,
        captures: [CapturedContext],
        mode: Mode,
        hadExternalProcessing: Bool
    ) {
        if hasUnsubmittedDraft {
            SubmissionPipeline.updateLastTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name,
                hadExternalProcessing: hadExternalProcessing
            )
        } else {
            SubmissionPipeline.recordTurn(
                history: transcriptionHistory, conversationID: conversationID,
                input: input, output: output, captures: captures,
                modeID: mode.id, modeName: mode.name,
                hadExternalProcessing: hadExternalProcessing
            )
        }
    }

    private func rebuildSessionForFollowUp(
        conversationID: UUID,
        followUpContext: String,
        previousActiveApp: NSRunningApplication?
    ) {
        session = PipelineSession()
        session?.conversationTurns = panel.currentTurns
        session?.conversationID = conversationID
        session?.followUpContext = followUpContext
        session?.previousActiveApp = previousActiveApp
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
