import AppKit
import OSLog

extension CapturePanel {

    /// Populates the panel with transcribed text during quick-action processing.
    /// Creates a pending displayed turn with nil output. The animated dots are
    /// driven by the `.processing` phase, not by a sentinel output value.
    /// Does NOT minimize — the panel is already minimized from recording start.
    func populateImmediateActionText(inputSegments: [InputSegment]) {
        viewModel?.displayedTurn = ConversationTurn(inputSegments: inputSegments, output: nil)
        viewModel?.errorMessage = nil
        // Phase is already .processing from handleTranscribing → setPhase(.processing)
    }

    /// Shows the processed result in the panel for preview confirmation.
    /// Sets the displayed turn with output, transitions to idle phase, and expands.
    func showPreview(text: String, modeName: String?) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = ConversationTurn(id: turn.id, inputSegments: turn.inputSegments, output: text)
        if let modeName {
            viewModel.processedByModeName = modeName
        }
        viewModel.phase = .idle
        expand()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, let turn = viewModel.displayedTurn else { return }
        viewModel.displayedTurn = ConversationTurn(id: turn.id, inputSegments: turn.inputSegments, output: outputText)
        viewModel.phase = .idle
        expand()
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
    }

    var isModeSwitcherVisible: Bool {
        viewModel?.modeSwitcherViewModel != nil
    }

    func setProcessedByModeName(_ name: String?) {
        viewModel?.processedByModeName = name
    }

    func setDestinationSubmitHandler(_ handler: @escaping (UUID) -> Void) {
        viewModel?.onDestinationSubmit = handler
    }

    func makeKeyIfVisible() {
        guard let panel, isVisible else { return }
        if isMinimized {
            expand()
            return
        }
        panel.makeKey()
    }
}
