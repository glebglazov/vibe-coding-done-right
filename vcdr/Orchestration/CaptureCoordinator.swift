import Foundation
import AppKit
import OSLog

@Observable
@MainActor
final class CaptureCoordinator {
    let settings: AppSettings
    let panel: CapturePanel
    let recordingIndicator: RecordingIndicatorPanel
    private let audioRecorder: AudioRecorder
    private let selectionCapturer: SelectionCapturer
    let clipboardMonitor: ClipboardMonitor
    let transcriptionHistory: TranscriptionHistory
    let overrides: SessionOverrides

    @ObservationIgnored var session: PipelineSession?

    @ObservationIgnored var accumulatedCaptures: [CapturedContext] = []

    @ObservationIgnored var pillResetTask: Task<Void, Never>?

    @ObservationIgnored var autoDismissTask: Task<Void, Never>?

    @ObservationIgnored var immediateActionTask: Task<Void, Never>?

    /// Stored snapshot while waiting for preview confirmation (Return key or destination hotkey).
    @ObservationIgnored var pendingPreviewSnapshot: SubmissionSnapshot?
    @ObservationIgnored var pendingPreviewText: String?

    @ObservationIgnored var onWillStartInput: (() -> Void)?

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
        overrides: SessionOverrides
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

    func showFromHistory(conversation: Conversation) {
        let displayTurn = DisplayedTurn(inputSegments: conversation.inputSegments, output: conversation.output)
        configurePanelAndShow(displayedTurn: displayTurn)
        if conversation.hadExternalProcessing {
            panel.setProcessedByModeName(conversation.modeName)
        }
        Logger.app.info("Capture view shown from history")
    }

    func rewirePanelCallbacks() {
        panel.onFocusLost = { [weak self] in
            self?.dismissOverlay()
        }
    }

    func configurePanelAndShow(
        displayedTurn: DisplayedTurn? = nil,
        minimized: Bool = false
    ) {
        rewirePanelCallbacks()

        panel.show(
            settings: settings,
            overrides: overrides,
            displayedTurn: displayedTurn,
            outputDestinations: settings.outputDestinations,
            initialAppName: session?.previousActiveApp?.localizedName,
            audioRecorder: audioRecorder,
            minimized: minimized,
            onDismiss: { [weak self] in
                self?.dismissOverlay()
            }
        )

        panel.viewModel?.onConfirm = { [weak self] in
            self?.confirmPreview()
        }
        panel.setDestinationSubmitHandler { [weak self] destinationID in
            self?.confirmPreviewWithDestination(destinationID)
        }
    }

    // MARK: - Preview Confirmation

    /// Confirms the pending preview — executes the stored action with the default destination.
    func confirmPreview() {
        guard let snapshot = pendingPreviewSnapshot, let processedText = pendingPreviewText else { return }
        let pipelineContext = snapshot.pipelineContext
        clearPendingPreview()

        executeConfirmedAction(snapshot: snapshot, processedText: processedText, pipelineContext: pipelineContext)
    }

    /// Confirms with a destination override — user pressed a destination hotkey during preview.
    func confirmPreviewWithDestination(_ destinationID: UUID) {
        guard let snapshot = pendingPreviewSnapshot, let processedText = pendingPreviewText else { return }

        // Rebuild context with the overridden destination
        overrides.destinationOverride = destinationID
        let destination = settings.outputDestination(for: destinationID)
        let overriddenContext = SubmissionPipeline.Context(
            text: snapshot.pipelineContext.text,
            mode: snapshot.mode,
            captures: snapshot.pipelineContext.captures,
            conversationID: snapshot.conversationID,
            parameterValues: snapshot.pipelineContext.parameterValues,
            destination: destination,
            targetAppPID: snapshot.pipelineContext.targetAppPID,
            saveResultToClipboard: snapshot.mode.saveResultToClipboard
        )
        let overriddenSnapshot = SubmissionSnapshot(
            pipelineContext: overriddenContext,
            mode: snapshot.mode,
            inputSegments: snapshot.inputSegments,
            conversationID: snapshot.conversationID,
            previousActiveApp: snapshot.previousActiveApp,
            destination: destination
        )
        clearPendingPreview()

        executeConfirmedAction(snapshot: overriddenSnapshot, processedText: processedText, pipelineContext: overriddenContext)
    }

    private func executeConfirmedAction(snapshot: SubmissionSnapshot, processedText: String, pipelineContext: SubmissionPipeline.Context) {
        panel.orderOut()

        Task { @MainActor in
            do {
                try await SubmissionPipeline.executeAction(
                    context: pipelineContext, processedText: processedText
                )
            } catch {
                panel.orderBack()
                panel.setError(error.localizedDescription)
                Logger.app.error("Preview confirmation action failed: \(error)")
                return
            }

            panel.dismiss()
            recordingIndicator.showSuccess(destinationName: snapshot.destination.name.lowercased())

            finalizeHistory(
                snapshot: snapshot, processedText: processedText,
                hadExternalProcessing: true
            )
            overrides.markPipelineCompleted()
            Logger.app.info("Preview confirmed and action executed")
        }
    }

    private func clearPendingPreview() {
        pendingPreviewSnapshot = nil
        pendingPreviewText = nil
    }

    func dismissOverlay(saveToHistory: Bool = true) {
        Task { await clipboardMonitor.stop() }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        immediateActionTask?.cancel()
        immediateActionTask = nil
        clearPendingPreview()
        panel.onFocusLost = nil
        panel.dismiss()
        recordingIndicator.showDismissed()
        session = nil
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
}
