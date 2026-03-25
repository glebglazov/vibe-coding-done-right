import AppKit
import OSLog

extension CapturePanel {

    func setSegments(_ segments: [InputSegment]) {
        viewModel?.inputSegments = segments
        viewModel?.activeSegmentIndex = max(0, segments.count - 1)
        resizePanel()
    }

    var segmentCount: Int { viewModel?.inputSegments.count ?? 0 }
    var allCaptures: [CapturedContext] { viewModel?.allCaptures ?? [] }
    var fullText: String { viewModel?.fullText ?? "" }

    /// Populates the panel with transcribed text during quick-action processing.
    /// Creates a pending displayed turn with nil output. The animated dots are
    /// driven by the `.processing` phase, not by a sentinel output value.
    /// Does NOT minimize — the panel is already minimized from recording start.
    func populateImmediateActionText(inputSegments: [InputSegment]) {
        viewModel?.displayedTurn = ConversationTurn(inputSegments: inputSegments, output: nil)
        viewModel?.errorMessage = nil
        // Phase is already .processing from handleTranscribing → setPhase(.processing)
        viewModel?.inputSegments = [InputSegment()]
    }

    func startProcessing() {
        let currentSegments = viewModel?.inputSegments ?? [InputSegment()]
        viewModel?.displayedTurn = ConversationTurn(inputSegments: currentSegments, output: nil)
        viewModel?.errorMessage = nil
        viewModel?.phase = .processing
        viewModel?.inputSegments = [InputSegment()]
        minimize()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = ConversationTurn(id: turn.id, inputSegments: turn.inputSegments, output: outputText)
        viewModel.phase = .idle
        expand()
    }

    /// Completes processing without setting output on the turn.
    /// Used when no external processing occurred — the turn keeps output == nil
    /// so conversation labels are not shown.
    func finishProcessingWithoutOutput() {
        guard let viewModel else { return }
        viewModel.phase = .idle
        expand()
    }

    func updateStreamingOutput(_ text: String) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = ConversationTurn(id: turn.id, inputSegments: turn.inputSegments, output: text)

        if viewModel.isMinimized {
            // Expand on first streaming chunk so user can watch output in real-time.
            // Don't use expand() — it resets phase to .idle, but we want to stay in .processing.
            viewModel.isMinimized = false
            resizePanelToExpanded()
            panel?.makeKey()
        } else {
            resizePanel()
        }
    }

    func finishStreaming(outputText: String) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = ConversationTurn(id: turn.id, inputSegments: turn.inputSegments, output: outputText)
        viewModel.phase = .idle
        resizePanel()
    }

    func showProcessingError(_ message: String) {
        guard let viewModel else { return }
        viewModel.displayedTurn = nil
        viewModel.errorMessage = message
        viewModel.phase = .error
        if viewModel.isMinimized {
            expand()
        } else {
            resizePanel()
        }
        Logger.actions.error("Capture panel processing failed: \(message)")
    }

    /// Restores input segments and shows an error after a pipeline failure.
    func restoreFromError(inputSegments: [InputSegment], error message: String) {
        guard let viewModel else { return }
        viewModel.inputSegments = inputSegments
        viewModel.activeSegmentIndex = max(0, inputSegments.count - 1)
        viewModel.errorMessage = message
        viewModel.phase = .error
        if viewModel.isMinimized {
            expand()
        } else {
            resizePanel()
        }
        Logger.actions.error("Capture panel processing failed: \(message)")
    }

    func setError(_ message: String) {
        guard let viewModel else { return }
        viewModel.errorMessage = message
        viewModel.phase = .error
        if viewModel.isMinimized {
            expand()
        } else {
            resizePanel()
        }
    }

    func updateInitialAppName(_ name: String?) {
        viewModel?.initialAppName = name
    }

    func buzz() {
        viewModel?.rejectCount += 1
    }

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        self.viewModel?.modeSwitcherViewModel = viewModel
    }

    func hideModeSwitcher() {
        self.viewModel?.modeSwitcherViewModel = nil
        if let contentView = panel?.contentView, let panel {
            focusActiveTextView(in: contentView, panel: panel)
        }
    }

    var isModeSwitcherVisible: Bool {
        viewModel?.modeSwitcherViewModel != nil
    }

    func setProcessedByModeName(_ name: String?) {
        viewModel?.processedByModeName = name
    }

    func setDestinationSubmitHandler(_ handler: @escaping (String, UUID) -> Void) {
        viewModel?.onDestinationSubmit = handler
    }

    func makeKeyIfVisible() {
        guard let panel, isVisible else { return }
        if isMinimized {
            expand()
            return
        }
        panel.makeKey()
        if let contentView = panel.contentView {
            focusActiveTextView(in: contentView, panel: panel)
        }
    }
}
