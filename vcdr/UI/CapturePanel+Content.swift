import AppKit
import OSLog

extension CapturePanel {

    func appendTextToActiveSegment(_ text: String) {
        guard let viewModel else { return }
        let index = viewModel.activeSegmentIndex
        guard viewModel.inputSegments.indices.contains(index) else { return }

        let segment = viewModel.inputSegments[index]
        let cursorPos = viewModel.savedCursorPositions[segment.id] ?? (segment.text as NSString).length
        let nsText = segment.text as NSString
        let clampedPos = min(cursorPos, nsText.length)

        // Insert at cursor position instead of appending to end
        viewModel.inputSegments[index].text = nsText.replacingCharacters(
            in: NSRange(location: clampedPos, length: 0),
            with: text
        )
        // Update saved position to right after the inserted text
        viewModel.savedCursorPositions[segment.id] = clampedPos + (text as NSString).length

        resizePanel()
    }

    func appendSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        viewModel.inputSegments.append(segment)
        viewModel.activeSegmentIndex = viewModel.inputSegments.count - 1
        resizePanel()
    }

    func addClipboardCapture(_ capture: CapturedContext) {
        guard let viewModel else { return }
        let activeIndex = viewModel.activeSegmentIndex
        if viewModel.inputSegments[activeIndex].capture == nil {
            // Active segment has no capture — attach to it
            viewModel.inputSegments[activeIndex].capture = capture
        } else {
            // Active segment already has a capture — insert new segment after it
            let segment = InputSegment(capture: capture)
            let insertIndex = min(activeIndex + 1, viewModel.inputSegments.count)
            viewModel.inputSegments.insert(segment, at: insertIndex)
            viewModel.activeSegmentIndex = insertIndex
        }
        resizePanel()
    }

    func setCapture(_ capture: CapturedContext, onSegmentAt index: Int) {
        guard let viewModel, viewModel.inputSegments.indices.contains(index) else { return }
        viewModel.inputSegments[index].capture = capture
        resizePanel()
    }

    func setSegments(_ segments: [InputSegment]) {
        viewModel?.inputSegments = segments
        viewModel?.activeSegmentIndex = max(0, segments.count - 1)
        resizePanel()
    }

    var segmentCount: Int { viewModel?.inputSegments.count ?? 0 }
    var allCaptures: [CapturedContext] { viewModel?.allCaptures ?? [] }
    var fullText: String { viewModel?.fullText ?? "" }

    /// Populates the panel with transcribed text during quick-action processing.
    /// Creates a pending conversation turn with "..." output so the history view
    /// shows "You: [text]" + "Result: [animated dots]" when expanded.
    /// Does NOT minimize — the panel is already minimized from recording start.
    func populateQuickActionText(inputSegments: [InputSegment]) {
        let pendingTurn = ConversationTurn(inputSegments: inputSegments, output: "...")
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.errorMessage = nil
        // Phase is already .processing from handleTranscribing → setPhase(.processing)
        viewModel?.inputSegments = [InputSegment()]
        viewModel?.scrollTrigger += 1
    }

    func startProcessing() {
        let currentSegments = viewModel?.inputSegments ?? [InputSegment()]
        let pendingTurn = ConversationTurn(inputSegments: currentSegments, output: "...")
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.errorMessage = nil
        viewModel?.phase = .processing
        viewModel?.inputSegments = [InputSegment()]
        viewModel?.scrollTrigger += 1
        minimize()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, inputSegments: lastTurn.inputSegments, output: outputText)
        viewModel.phase = .idle
        viewModel.scrollTrigger += 1
        expand()
    }

    func updateStreamingOutput(_ text: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, inputSegments: lastTurn.inputSegments, output: text)
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
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, inputSegments: lastTurn.inputSegments, output: outputText)
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
    func restoreConversation(turns: [ConversationTurn], inputSegments: [InputSegment], error message: String) {
        guard let viewModel else { return }
        viewModel.conversationTurns = turns
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

    func signalClipboardCapture() {
        viewModel?.clipboardCaptureCount += 1
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
        let latestText = viewModel.conversationTurns.last(where: { $0.output != nil })?.output ?? viewModel.conversationTurns.last?.input ?? ""
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
