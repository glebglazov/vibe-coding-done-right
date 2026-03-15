import AppKit
import OSLog

extension CapturePanel {

    func appendTextToActiveSegment(_ text: String) {
        guard let viewModel else { return }
        let index = viewModel.activeSegmentIndex
        guard viewModel.segments.indices.contains(index) else { return }

        let segment = viewModel.segments[index]
        let cursorPos = viewModel.savedCursorPositions[segment.id] ?? (segment.text as NSString).length
        let nsText = segment.text as NSString
        let clampedPos = min(cursorPos, nsText.length)

        // Insert at cursor position instead of appending to end
        viewModel.segments[index].text = nsText.replacingCharacters(
            in: NSRange(location: clampedPos, length: 0),
            with: text
        )
        // Update saved position to right after the inserted text
        viewModel.savedCursorPositions[segment.id] = clampedPos + (text as NSString).length

        resizePanel()
    }

    func appendSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        viewModel.segments.append(segment)
        viewModel.activeSegmentIndex = viewModel.segments.count - 1
        resizePanel()
    }

    func addClipboardCapture(_ capture: CapturedContext) {
        guard let viewModel else { return }
        let activeIndex = viewModel.activeSegmentIndex
        if viewModel.segments[activeIndex].capture == nil {
            // Active segment has no capture — attach to it
            viewModel.segments[activeIndex].capture = capture
        } else {
            // Active segment already has a capture — insert new segment after it
            let segment = InputSegment(capture: capture)
            let insertIndex = min(activeIndex + 1, viewModel.segments.count)
            viewModel.segments.insert(segment, at: insertIndex)
            viewModel.activeSegmentIndex = insertIndex
        }
        resizePanel()
    }

    func setCapture(_ capture: CapturedContext, onSegmentAt index: Int) {
        guard let viewModel, viewModel.segments.indices.contains(index) else { return }
        viewModel.segments[index].capture = capture
        resizePanel()
    }

    func setSegments(_ segments: [InputSegment]) {
        viewModel?.segments = segments
        viewModel?.activeSegmentIndex = max(0, segments.count - 1)
        resizePanel()
    }

    var segmentCount: Int { viewModel?.segments.count ?? 0 }
    var allCaptures: [CapturedContext] { viewModel?.allCaptures ?? [] }
    var fullText: String { viewModel?.fullText ?? "" }

    func startProcessing(inputText: String) {
        let captures = viewModel?.allCaptures ?? []
        let pendingTurn = ConversationTurn(input: inputText, output: "...", captures: captures)
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.errorMessage = nil
        viewModel?.phase = .processing
        viewModel?.segments = [InputSegment()]
        viewModel?.scrollTrigger += 1
        minimize()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: outputText, captures: lastTurn.captures)
        viewModel.phase = .idle
        viewModel.scrollTrigger += 1
        expand()
    }

    func updateStreamingOutput(_ text: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: text, captures: lastTurn.captures)
        viewModel.scrollTrigger += 1

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
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: outputText, captures: lastTurn.captures)
        viewModel.phase = .idle
        viewModel.scrollTrigger += 1
        resizePanel()
    }

    func showProcessingError(_ message: String) {
        guard let viewModel else { return }
        // Remove the pending "..." turn if one was added by startProcessing.
        // For non-bashScript modes, startProcessing is not called, so there may be no pending turn.
        if !viewModel.conversationTurns.isEmpty {
            viewModel.conversationTurns.removeLast()
        }
        viewModel.errorMessage = message
        viewModel.phase = .error
        if viewModel.isMinimized {
            expand()
        } else {
            // Panel is already expanded (non-bashScript mode) — resize to fit error banner
            resizePanel()
        }
        Logger.actions.error("Capture panel processing failed: \(message)")
    }

    /// Restores the full conversation state from before submission and shows an error.
    /// Called when the pipeline or action fails so the user sees their original
    /// conversation + input and can fix the issue and retry.
    func restoreConversation(turns: [ConversationTurn], segments: [InputSegment], error message: String) {
        guard let viewModel else { return }
        viewModel.conversationTurns = turns
        viewModel.segments = segments
        viewModel.activeSegmentIndex = max(0, segments.count - 1)
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
        viewModel?.errorMessage = message
        viewModel?.phase = .error
        resizePanel()
    }

    func signalClipboardCapture() {
        viewModel?.clipboardCaptureCount += 1
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

    struct FollowUpState {
        let turns: [ConversationTurn]
        let text: String
    }

    func readFollowUpState() -> FollowUpState? {
        guard isVisible,
              let viewModel,
              !viewModel.conversationTurns.isEmpty else {
            return nil
        }
        let latestText = viewModel.conversationTurns.last?.output ?? ""
        return FollowUpState(turns: viewModel.conversationTurns, text: latestText)
    }

    func lockForFollowUp() {
        isLockedForFollowUp = true
    }

    func unlockFollowUp() {
        isLockedForFollowUp = false
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
