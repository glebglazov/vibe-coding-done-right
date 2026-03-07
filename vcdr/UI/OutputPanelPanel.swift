import AppKit
import SwiftUI
import OSLog

@MainActor
final class OutputPanelPanel {
    private var panel: NSPanel?
    private var viewModel: OutputPanelViewModel?
    private var localEventMonitor: Any?
    private var becameKeyObserver: NSObjectProtocol?

    /// Callback invoked when the user submits inline text via Return key
    var onSubmitText: ((String) -> Void)?

    /// Callback invoked when the user presses Escape while the panel is locked for follow-up
    /// (recording/processing in progress). Cancels the in-flight recording or processing.
    var onCancelRecording: (() -> Void)?

    /// When true, the panel ignores dismiss triggers (global clicks, Escape, Cmd+C).
    /// Set during follow-up recording/typing so the panel stays visible.
    private(set) var isLockedForFollowUp = false

    // MARK: - Current Session State

    /// Conversation turns including the latest, for follow-up continuation.
    private(set) var currentTurns: [ConversationTurn] = []
    /// The latest processed output text, used as follow-up context for the next recording.
    private(set) var currentText: String?
    /// Mode that produced the current output.
    private(set) var currentModeID: UUID?
    /// Conversation ID for the current session.
    private(set) var currentConversationID: UUID?
    /// Whether this session supports follow-up (only true for modes with bash processing).
    private var canFollowUp = false

    // MARK: - Constants

    private static let panelWidth: CGFloat = 480
    private static let panelMinHeight: CGFloat = 96
    private static let panelMaxHeight: CGFloat = 600
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    /// Approximate height per line of monospaced body text
    private static let lineHeight: CGFloat = 20
    /// Padding around text content (top + bottom)
    private static let contentPadding: CGFloat = 32
    /// Height of the hint bar at the bottom
    private static let hintBarHeight: CGFloat = 30
    /// Height of a "You:" or "Result:" label line
    private static let labelLineHeight: CGFloat = 18
    /// Height of a divider between turns
    private static let turnDividerHeight: CGFloat = 10
    /// Height of the inline text input area (TextEditor 60pt + divider 8pt)
    private static let textInputHeight: CGFloat = 68

    func show(
        inputText: String,
        text: String,
        capturedSelection: String?,
        conversationTurns: [ConversationTurn],
        outputDestinations: [OutputDestination],
        targetAppPID: pid_t?,
        modeID: UUID,
        conversationID: UUID,
        canFollowUp: Bool
    ) {
        tearDown()

        let allTurns = conversationTurns + [ConversationTurn(input: inputText, output: text, capturedSelection: capturedSelection)]
        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        // Store session state for follow-up continuation
        self.currentTurns = allTurns
        self.currentText = text
        self.currentModeID = modeID
        self.currentConversationID = conversationID
        self.canFollowUp = canFollowUp

        let viewModel = OutputPanelViewModel(
            conversationTurns: allTurns,
            outputDestinations: filteredDestinations,
            isReadOnly: !canFollowUp,
            onCopy: { [weak self] in
                guard let self, let latestText = self.currentText else { return }
                self.copyToClipboard(latestText)
            },
            onFireDestination: { [weak self] destination in
                guard let self, let latestText = self.currentText else { return }
                self.fireDestination(destination, text: latestText, targetAppPID: targetAppPID, conversationID: self.currentConversationID ?? conversationID)
            },
            onDismiss: { [weak self] in
                self?.hide()
            },
            onSubmitText: { [weak self] text in
                self?.onSubmitText?(text)
            }
        )
        self.viewModel = viewModel

        presentPanel(viewModel: viewModel, turns: allTurns, isReadOnly: !canFollowUp)
        Logger.actions.info("Output panel shown")
    }

    /// Opens the output panel displaying a conversation loaded from history.
    /// If `canContinue` is true, follow-up input is enabled and the panel
    /// is set up for conversation continuation. If false, the panel is read-only.
    func showFromHistory(
        conversation: Conversation,
        outputDestinations: [OutputDestination],
        canContinue: Bool
    ) {
        tearDown()

        let turns = conversation.turns.map { turn in
            ConversationTurn(input: turn.input, output: turn.output, capturedSelection: turn.capturedSelection)
        }
        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        // Store session state for follow-up continuation
        self.currentTurns = turns
        self.currentText = conversation.latestOutput
        self.currentModeID = canContinue ? conversation.modeID : nil
        self.currentConversationID = conversation.id
        self.canFollowUp = canContinue

        let viewModel = OutputPanelViewModel(
            conversationTurns: turns,
            outputDestinations: filteredDestinations,
            isReadOnly: !canContinue,
            onCopy: { [weak self] in
                guard let self, let latestText = self.currentText else { return }
                self.copyToClipboard(latestText)
            },
            onFireDestination: { [weak self] destination in
                guard let self, let latestText = self.currentText else { return }
                self.fireDestination(
                    destination,
                    text: latestText,
                    targetAppPID: nil,
                    conversationID: self.currentConversationID ?? conversation.id
                )
            },
            onDismiss: { [weak self] in
                self?.hide()
            },
            onSubmitText: { [weak self] text in
                self?.onSubmitText?(text)
            }
        )
        self.viewModel = viewModel

        presentPanel(viewModel: viewModel, turns: turns, isReadOnly: !canContinue)
        Logger.actions.info("Output panel shown from history (canContinue=\(canContinue))")
    }

    // MARK: - Panel Presentation

    /// Creates the NSPanel, positions it below the menu bar, sets up event monitoring,
    /// and focuses the text view. Shared by `show()` and `showFromHistory()`.
    private func presentPanel(viewModel: OutputPanelViewModel, turns: [ConversationTurn], isReadOnly: Bool) {
        let view = OutputPanelView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: turns, isReadOnly: isReadOnly)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.panelWidth / 2
            let y = screenFrame.maxY - menuBarHeight - panelHeight - Self.panelOffsetBelowMenuBar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Focus the TextEditor's underlying NSTextView for immediate keyboard input
        // (only when not read-only — read-only panels have no text editor)
        if !isReadOnly, let contentView = panel.contentView {
            Self.focusFirstTextView(in: contentView, panel: panel)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel, weak panel] event in
            guard let viewModel, panel?.isKeyWindow == true else { return event }
            return viewModel.handleKeyEvent(event) ? nil : event
        }

        // Re-focus the text view when this panel regains key status (only when not read-only)
        if !isReadOnly {
            becameKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                guard let self, let contentView = self.panel?.contentView, let panel = self.panel else { return }
                Self.focusFirstTextView(in: contentView, panel: panel)
            }
        }
    }

    func hide() {
        // When locked for follow-up (recording/processing in progress), cancel the recording
        // instead of dismissing. The panel stays visible — cancelRecording() will unlock it.
        if isLockedForFollowUp {
            onCancelRecording?()
            return
        }
        tearDown()
    }

    /// Unconditionally closes the panel and clears all state, ignoring the follow-up lock.
    /// Used by `show()` to tear down the previous panel before creating a new one.
    private func tearDown() {
        isLockedForFollowUp = false
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = becameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            becameKeyObserver = nil
        }
        panel?.close()
        panel = nil
        viewModel = nil

        // Clear session state
        currentTurns = []
        currentText = nil
        currentModeID = nil
        currentConversationID = nil
        canFollowUp = false
    }

    var isVisible: Bool { panel != nil }

    // MARK: - Follow-up State Capture

    /// Captures the current session state and hides the panel.
    /// Returns nil if the panel is not visible.
    struct FollowUpState {
        let turns: [ConversationTurn]
        let text: String
        let modeID: UUID
        let conversationID: UUID
    }

    func captureFollowUpState() -> FollowUpState? {
        guard canFollowUp,
              isVisible,
              let text = currentText,
              let modeID = currentModeID,
              let conversationID = currentConversationID else {
            return nil
        }
        let turns = currentTurns
        tearDown()
        return FollowUpState(turns: turns, text: text, modeID: modeID, conversationID: conversationID)
    }

    /// Reads the current follow-up state without hiding the panel.
    /// Use when the output panel should remain visible during follow-up recording/typing.
    func readFollowUpState() -> FollowUpState? {
        guard canFollowUp,
              isVisible,
              let text = currentText,
              let modeID = currentModeID,
              let conversationID = currentConversationID else {
            return nil
        }
        return FollowUpState(turns: currentTurns, text: text, modeID: modeID, conversationID: conversationID)
    }

    /// Prevents the panel from auto-dismissing (global clicks, Escape, Cmd+C).
    /// Call when starting a follow-up recording or push-to-type session.
    func lockForFollowUp() {
        isLockedForFollowUp = true
    }

    /// Re-enables normal dismiss behavior.
    /// Call when the follow-up recording/typing session ends.
    func unlockFollowUp() {
        isLockedForFollowUp = false
    }

    /// Current height of the panel, for offset calculations when positioning other panels below.
    var currentPanelHeight: CGFloat { panel?.frame.height ?? 0 }

    /// Reclaims key window status so the inline text input receives focus.
    func makeKeyIfVisible() {
        guard let panel, isVisible else { return }
        panel.makeKey()
        if let contentView = panel.contentView {
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    // MARK: - Height Calculation

    private static func calculateHeight(for turns: [ConversationTurn], isReadOnly: Bool = false) -> CGFloat {
        var totalLines: CGFloat = 0
        // Show labels when multiple turns, or (for non-read-only modes) input was transformed
        // or captured selection is present. Read-only (non-processing) modes never show labels
        // for a single turn — the user just wants to see the final text.
        let showLabels = turns.count > 1
            || (!isReadOnly && ((turns.first.map { $0.input != $0.output } ?? false)
                || turns.contains(where: { $0.capturedSelection != nil })))

        for (index, turn) in turns.enumerated() {
            if showLabels {
                // "You:" label + input lines + "Result:" label
                totalLines += CGFloat(turn.input.components(separatedBy: .newlines).count)
                let labelOverhead = 2 * labelLineHeight / lineHeight // Two labels per turn
                totalLines += labelOverhead
            }
            // Captured selection blockquote ("Context:" label + selection lines)
            if showLabels, let selection = turn.capturedSelection {
                totalLines += labelLineHeight / lineHeight  // "Context:" label
                let selectionLines = CGFloat(selection.components(separatedBy: .newlines).count)
                totalLines += selectionLines * 0.9  // callout font is slightly smaller than body
            }

            totalLines += CGFloat(turn.output.components(separatedBy: .newlines).count)

            // Divider between turns (not after last)
            if index < turns.count - 1 {
                totalLines += turnDividerHeight / lineHeight
            }
        }

        let estimatedTextHeight = totalLines * lineHeight
        let inputHeight: CGFloat = isReadOnly ? 0 : textInputHeight
        let totalHeight = estimatedTextHeight + contentPadding + hintBarHeight + inputHeight
        return min(max(totalHeight, panelMinHeight), panelMaxHeight)
    }

    // MARK: - In-Place Processing

    func startProcessing(inputText: String) {
        let pendingTurn = ConversationTurn(input: inputText, output: "...")
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.isProcessing = true
        viewModel?.inlineText = ""
        currentTurns = viewModel?.conversationTurns ?? currentTurns
        viewModel?.scrollTrigger += 1
        resizePanel()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(input: lastTurn.input, output: outputText)
        currentText = outputText
        viewModel.isProcessing = false
        currentTurns = viewModel.conversationTurns
        viewModel.scrollTrigger += 1
        resizePanel()
    }

    func showProcessingError(_ message: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        viewModel.conversationTurns.removeLast()
        currentTurns = viewModel.conversationTurns
        viewModel.isProcessing = false
        resizePanel()
        Logger.actions.error("Output panel inline processing failed: \(message)")
    }

    /// Recalculates and animates panel height based on current conversation turns
    private func resizePanel() {
        guard let panel else { return }
        let isReadOnly = viewModel?.isReadOnly ?? false
        let newHeight = Self.calculateHeight(for: currentTurns, isReadOnly: isReadOnly)
        let currentFrame = panel.frame
        // Grow/shrink upward: keep top edge pinned
        let newY = currentFrame.maxY - newHeight
        let newFrame = NSRect(x: currentFrame.origin.x, y: newY, width: currentFrame.width, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Constants (Focus)

    /// Maximum number of attempts to find and focus the NSTextView
    private static let focusMaxAttempts = 10
    /// Delay between focus retry attempts, giving SwiftUI time to lay out the view hierarchy
    private static let focusRetryDelay: Duration = .milliseconds(10)

    // MARK: - Focus Management

    /// Walks the view hierarchy to find the NSTextView created by SwiftUI's TextEditor
    /// and makes it the panel's first responder for immediate keyboard input.
    /// Retries with a short delay because SwiftUI may need multiple run loop iterations
    /// to fully insert the NSTextView into the hosting view's hierarchy.
    private static func focusFirstTextView(in view: NSView, panel: NSPanel) {
        Task { @MainActor in
            for _ in 0..<focusMaxAttempts {
                if let textView = findFirstTextView(in: view) {
                    panel.makeFirstResponder(textView)
                    // Verify focus actually took — another responder may have stolen it
                    if panel.firstResponder === textView {
                        return
                    }
                }
                try? await Task.sleep(for: focusRetryDelay)
            }
            Logger.ui.warning("Output panel: failed to focus text view after \(focusMaxAttempts) attempts")
        }
    }

    private static func findFirstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = findFirstTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.actions.info("Output panel: text copied to clipboard")
    }

    private func fireDestination(_ destination: OutputDestination, text: String, targetAppPID: pid_t?, conversationID: UUID) {
        tearDown()
        Task {
            do {
                guard let action = OutputActionFactory.makeAction(for: destination, targetAppPID: targetAppPID, conversationID: conversationID) else { return }
                try await action.execute(text: text)
                Logger.actions.info("Output panel: fired destination '\(destination.name)'")
            } catch {
                Logger.actions.error("Output panel: destination failed: \(error)")
            }
        }
    }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
