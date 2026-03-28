import AppKit
import OSLog

extension CapturePanel {

    /// Populates the panel with transcribed text during quick-action processing.
    /// Creates a pending displayed turn with nil output. The animated dots are
    /// driven by the `.processing` phase, not by a sentinel output value.
    /// Does NOT minimize — the panel is already minimized from recording start.
    func populateImmediateActionText(inputSegments: [InputSegment]) {
        viewModel?.displayedTurn = DisplayedTurn(inputSegments: inputSegments, output: nil)
        viewModel?.phaseState.errorMessage = nil
        // Phase is already .processing from handleTranscribing → setPhase(.processing)
    }

    /// Shows the processed result in the panel for preview confirmation.
    /// Sets the displayed turn with output, transitions to idle phase, and expands.
    func showPreview(text: String, modeName: String?) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = DisplayedTurn(id: turn.id, inputSegments: turn.inputSegments, output: text)
        if let modeName {
            viewModel.processedByModeName = modeName
        }
        viewModel.phaseState.phase = .idle
        expand()
    }

    func setError(_ message: String) {
        guard let viewModel else { return }
        viewModel.phaseState.errorMessage = message
        viewModel.phaseState.phase = .error
        if viewModel.isMinimized {
            expand()
        } else {
            resizePanel()
        }
    }

    func buzz() {
        viewModel?.feedbackCounters.rejectCount += 1
    }

}
