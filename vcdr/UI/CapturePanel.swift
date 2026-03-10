import AppKit
import SwiftUI
import OSLog

@MainActor
final class CapturePanel {
    private var panel: NSPanel?
    private var viewModel: CaptureViewModel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var becameKeyObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    /// Called when the panel loses focus (click outside, app switch).
    var onFocusLost: (() -> Void)?

    /// Called when the minimized pill is clicked or the panel regains key status while minimized.
    var onPillClicked: (() -> Void)?

    /// Callback invoked when the user submits inline text via Return key
    var onSubmitText: ((String) -> Void)?

    /// Callback invoked when the user presses Escape while locked for follow-up
    var onCancelRecording: (() -> Void)?

    /// Callback invoked when the user presses the cancel capture hotkey
    var onCancelCapture: (() -> Void)?

    /// When true, the panel ignores dismiss triggers.
    /// Set during follow-up recording so the panel stays visible.
    private(set) var isLockedForFollowUp = false

    // MARK: - Constants

    private static let panelWidth: CGFloat = 480
    private static let panelBaseHeight: CGFloat = 140
    private static let panelMaxHeightFraction: CGFloat = 0.85
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let minimizedPanelWidth: CGFloat = 200
    private static let minimizedPanelHeight: CGFloat = 40
    /// Delay to let resize animation finish and SwiftUI lay out the TextEditor
    private static let expandFocusDelay: Duration = .milliseconds(200)
    /// Approximate height per line of monospaced body text
    private static let lineHeight: CGFloat = 20
    /// Height of a "You:" or "Result:" label line
    private static let labelLineHeight: CGFloat = 18
    /// Height of a divider between turns
    private static let turnDividerHeight: CGFloat = 10
    /// Padding around the conversation history section
    private static let conversationPadding: CGFloat = 24
    /// Height of the hint bar at the bottom
    private static let hintBarHeight: CGFloat = 30
    /// Height of the text input area (TextEditor 60pt + divider 8pt)
    private static let textInputHeight: CGFloat = 68

    // MARK: - Lifecycle

    func show(
        settings: AppSettings,
        conversationTurns: [ConversationTurn] = [],
        captures: [CapturedContext] = [],
        outputDestinations: [OutputDestination] = [],
        audioRecorder: AudioRecorder? = nil,
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        tearDown()

        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        let viewModel = CaptureViewModel(
            settings: settings,
            conversationTurns: conversationTurns,
            captures: captures,
            outputDestinations: filteredDestinations,
            onSubmit: { text in
                onSubmit(text)
            },
            onDismiss: {
                onDismiss()
            },
            onExpand: { [weak self] in
                self?.expand()
            },
            audioRecorder: audioRecorder
        )
        viewModel.onCancelCapture = onCancelCapture
        self.viewModel = viewModel

        presentPanel(viewModel: viewModel, turns: conversationTurns, captures: captures)
    }

    func hide() {
        if isLockedForFollowUp {
            onCancelRecording?()
            return
        }
        tearDown()
    }

    /// Unconditionally closes the panel regardless of follow-up lock state.
    func dismiss() {
        tearDown()
    }

    private func tearDown() {
        isLockedForFollowUp = false
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = becameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            becameKeyObserver = nil
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        panel?.close()
        panel = nil
        viewModel = nil
    }

    // MARK: - State Access

    var isVisible: Bool { panel != nil }

    var isMinimized: Bool { viewModel?.isMinimized ?? false }

    var currentText: String? { viewModel?.text }

    var currentTurns: [ConversationTurn] { viewModel?.conversationTurns ?? [] }

    // MARK: - Panel Presentation

    private func presentPanel(viewModel: CaptureViewModel, turns: [ConversationTurn], captures: [CapturedContext]) {
        let view = CaptureView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: turns, captures: captures)
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

        // Focus the TextEditor unless we're in recording mode
        if !viewModel.isRecording {
            Self.focusFirstTextView(in: hostingView, panel: panel)
        }

        // Intercept Return (submit) and Escape (dismiss) before they reach the text field.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel, weak panel] event in
            guard let viewModel, panel?.isKeyWindow == true else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // When the panel regains key status: if minimized, notify coordinator
        // to expand; if expanded, re-focus the text view.
        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak hostingView, weak panel] _ in
            guard let self else { return }
            if self.viewModel?.isMinimized == true {
                self.onPillClicked?()
                return
            }
            guard let hostingView, let panel else { return }
            if self.viewModel?.isRecording != true {
                Self.focusFirstTextView(in: hostingView, panel: panel)
            }
        }

        // Auto-collapse when the panel loses key window status.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isLockedForFollowUp else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }

        // Collapse if the user clicks outside the panel.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isLockedForFollowUp else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }

        Logger.ui.info("Capture panel shown")
    }

    // MARK: - Minimize / Expand

    func minimize(phase: CaptureViewModel.PillPhase = .idle) {
        var effectivePhase = phase
        if phase == .idle && viewModel?.isRecording == true { effectivePhase = .recording }
        if phase == .idle && viewModel?.isProcessing == true { effectivePhase = .processing }
        viewModel?.pillPhase = effectivePhase
        guard viewModel?.isMinimized != true else { return }
        viewModel?.isMinimized = true
        resizePanelToMinimized()
        panel?.resignKey()
    }

    func expand() {
        guard viewModel?.isMinimized == true else { return }
        viewModel?.isMinimized = false
        viewModel?.pillPhase = .idle
        resizePanelToExpanded()
        panel?.makeKey()
        if viewModel?.isRecording != true {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.expandFocusDelay)
                guard let self, let contentView = self.panel?.contentView, let panel = self.panel else { return }
                Self.focusFirstTextView(in: contentView, panel: panel)
            }
        }
    }

    // MARK: - Recording State

    func setRecording(_ recording: Bool) {
        viewModel?.isRecording = recording
        if recording {
            viewModel?.pillPhase = .recording
        }
    }

    func showPillError() {
        viewModel?.pillPhase = .error
    }

    func setPillPhase(_ phase: CaptureViewModel.PillPhase) {
        viewModel?.pillPhase = phase
    }

    // MARK: - Text Insertion

    /// Inserts text at the NSTextView's current cursor position.
    func insertTextAtCursor(_ text: String) {
        guard let contentView = panel?.contentView,
              let textView = Self.findFirstTextView(in: contentView) else {
            // Fallback: append to view model text
            viewModel?.text += text
            return
        }
        let range = textView.selectedRange()
        textView.insertText(text, replacementRange: range)
        // Sync view model text with NSTextView
        viewModel?.text = textView.string
    }

    // MARK: - Conversation Updates

    func startProcessing(inputText: String) {
        let pendingTurn = ConversationTurn(input: inputText, output: "...")
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.isProcessing = true
        viewModel?.text = ""
        viewModel?.scrollTrigger += 1
        minimize(phase: .processing)
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: outputText)
        viewModel.isProcessing = false
        viewModel.scrollTrigger += 1
        expand()
    }

    func updateStreamingOutput(_ text: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: text, captures: lastTurn.captures)
        viewModel.scrollTrigger += 1
    }

    func finishStreaming(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: outputText, captures: lastTurn.captures)
        viewModel.isProcessing = false
        viewModel.scrollTrigger += 1
        resizePanel()
    }

    func setProcessing(_ processing: Bool) {
        viewModel?.isProcessing = processing
    }

    func showProcessingError(_ message: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        viewModel.conversationTurns.removeLast()
        viewModel.isProcessing = false
        expand()
        Logger.actions.error("Capture panel processing failed: \(message)")
    }

    // MARK: - Captures / Mode Switcher / Destination

    func updateCaptures(_ captures: [CapturedContext]) {
        viewModel?.captures = captures
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
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    var isModeSwitcherVisible: Bool {
        viewModel?.modeSwitcherViewModel != nil
    }

    func updateOutputDestinationOverride(_ id: UUID?) {
        viewModel?.outputDestinationOverrideID = id
    }

    func updateParameterLabels(_ labels: String?) {
        viewModel?.parameterLabels = labels
    }

    func setDestinationSubmitHandler(_ handler: @escaping (String, UUID) -> Void) {
        viewModel?.onDestinationSubmit = handler
    }

    // MARK: - Follow-up State

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

    /// Reclaims key window status so the inline text input receives focus.
    func makeKeyIfVisible() {
        guard let panel, isVisible else { return }
        if isMinimized {
            expand()
            return
        }
        panel.makeKey()
        if let contentView = panel.contentView {
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    // MARK: - Resize

    private func resizePanelToMinimized() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.minimizedPanelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - Self.minimizedPanelHeight - Self.panelOffsetBelowMenuBar
        let newFrame = NSRect(x: x, y: y, width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func resizePanelToExpanded() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let turns = viewModel?.conversationTurns ?? []
        let caps = viewModel?.captures ?? []
        let newHeight = Self.calculateHeight(for: turns, captures: caps)
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar
        let newFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    /// Recalculates and animates panel height based on current content
    private func resizePanel() {
        guard let panel else { return }
        let turns = viewModel?.conversationTurns ?? []
        let caps = viewModel?.captures ?? []
        let newHeight = Self.calculateHeight(for: turns, captures: caps)
        let currentFrame = panel.frame
        let newY = currentFrame.maxY - newHeight
        let newFrame = NSRect(x: currentFrame.origin.x, y: newY, width: currentFrame.width, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Height Calculation

    private static func maxPanelHeight() -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return visibleHeight * panelMaxHeightFraction
    }

    private static func calculateHeight(for turns: [ConversationTurn], captures: [CapturedContext] = []) -> CGFloat {
        var extraHeight: CGFloat = 0

        // Captured context blockquotes
        for capture in captures {
            let captureLines = CGFloat(capture.text.components(separatedBy: .newlines).count)
            extraHeight += labelLineHeight  // source label
            extraHeight += captureLines * lineHeight * 0.9
        }
        if !captures.isEmpty {
            extraHeight += conversationPadding
        }

        guard !turns.isEmpty else {
            let total = panelBaseHeight + extraHeight
            return min(total, maxPanelHeight())
        }

        var totalLines: CGFloat = 0
        for (index, turn) in turns.enumerated() {
            // "You:" label + input lines + "Result:" label + output lines
            totalLines += labelLineHeight / lineHeight
            totalLines += CGFloat(turn.input.components(separatedBy: .newlines).count)
            totalLines += labelLineHeight / lineHeight
            totalLines += CGFloat(turn.output.components(separatedBy: .newlines).count)

            // Captured context in turns
            for capture in turn.captures {
                totalLines += labelLineHeight / lineHeight
                totalLines += CGFloat(capture.text.components(separatedBy: .newlines).count) * 0.9
            }

            if index < turns.count - 1 {
                totalLines += turnDividerHeight / lineHeight
            }
        }

        let conversationHeight = totalLines * lineHeight + conversationPadding
        let total = panelBaseHeight + conversationHeight + extraHeight
        return min(total, maxPanelHeight())
    }

    // MARK: - Constants (Focus)

    private static let focusMaxAttempts = 10
    private static let focusRetryDelay: Duration = .milliseconds(10)

    // MARK: - Focus Management

    private static func focusFirstTextView(in view: NSView, panel: NSPanel) {
        Task { @MainActor in
            for _ in 0..<focusMaxAttempts {
                if let textView = findFirstTextView(in: view) {
                    panel.makeFirstResponder(textView)
                    if panel.firstResponder === textView {
                        return
                    }
                }
                try? await Task.sleep(for: focusRetryDelay)
            }
            Logger.ui.warning("Capture panel: failed to focus text view after \(focusMaxAttempts) attempts")
        }
    }

    static func findFirstTextView(in view: NSView) -> NSTextView? {
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
}
