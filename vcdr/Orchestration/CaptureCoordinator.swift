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
    let overrides: ConversationOverrides

    @ObservationIgnored var session: PipelineSession?

    @ObservationIgnored var accumulatedCaptures: [CapturedContext] = []

    @ObservationIgnored var pillResetTask: Task<Void, Never>?

    @ObservationIgnored var autoDismissTask: Task<Void, Never>?

    @ObservationIgnored var immediateActionTask: Task<Void, Never>?

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

    func showFromHistory(conversation: Conversation) {
        let editorSegments = conversation.inputSegments.isEmpty
            ? [InputSegment()] : conversation.inputSegments

        // Show the turn display if there's processed output
        let displayTurn: ConversationTurn? = conversation.hadExternalProcessing
            ? ConversationTurn(inputSegments: conversation.inputSegments, output: conversation.output)
            : nil

        configurePanelAndShow(displayedTurn: displayTurn, inputSegments: editorSegments)
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

    private func clearSubmissionCallbacks() {
        Task { await clipboardMonitor.stop() }
        panel.onFocusLost = nil
        accumulatedCaptures = []
    }

    func configurePanelAndShow(
        displayedTurn: ConversationTurn? = nil,
        inputSegments: [InputSegment]? = nil,
        minimized: Bool = false
    ) {
        rewirePanelCallbacks()

        let resolvedSegments = inputSegments ?? [InputSegment()]

        panel.show(
            settings: settings,
            overrides: overrides,
            displayedTurn: displayedTurn,
            inputSegments: resolvedSegments,
            outputDestinations: settings.outputDestinations,
            initialAppName: session?.previousActiveApp?.localizedName,
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

    func dismissOverlay(saveToHistory: Bool = true) {
        // Persist any non-empty input to history before tearing down the session.
        if saveToHistory {
            preserveCurrentInputToHistory()
        }

        Task { await clipboardMonitor.stop() }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        immediateActionTask?.cancel()
        immediateActionTask = nil
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

    // MARK: - History Preservation

    /// Saves the current panel content to history on dismiss so no input is lost.
    private func preserveCurrentInputToHistory() {
        guard let session, let conversationID = session.conversationID else { return }

        let segments = panel.viewModel?.inputSegments ?? []
        let hasContent = segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.capture != nil }
        guard hasContent else { return }

        recordHistory(
            conversationID: conversationID,
            inputSegments: segments, output: nil,
            mode: settings.activeMode
        )
    }

}
