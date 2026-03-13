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
        overrides: ConversationOverrides,
        conversationTurns: [ConversationTurn] = [],
        segments: [InputSegment] = [InputSegment()],
        outputDestinations: [OutputDestination] = [],
        audioRecorder: AudioRecorder? = nil,
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        tearDown()

        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        let viewModel = CaptureViewModel(
            settings: settings,
            overrides: overrides,
            conversationTurns: conversationTurns,
            segments: segments,
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

        presentPanel(viewModel: viewModel, turns: conversationTurns, segments: segments)
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

    var currentText: String? { viewModel?.fullText }

    var currentTurns: [ConversationTurn] { viewModel?.conversationTurns ?? [] }

    // MARK: - Panel Presentation

    private func presentPanel(viewModel: CaptureViewModel, turns: [ConversationTurn], segments: [InputSegment] = [InputSegment()]) {
        let view = CaptureView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: turns, segments: segments)
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
                // Don't expand the pill when it regains key status during recording —
                // this can happen when another panel (e.g. mode switcher) closes and
                // returns focus to the capture panel. Only expand on intentional clicks.
                guard self.viewModel?.isRecording != true else { return }
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

    func minimize() {
        guard viewModel?.isMinimized != true else { return }
        viewModel?.isMinimized = true
        resizePanelToMinimized()
        panel?.resignKey()
    }

    func expand() {
        guard viewModel?.isMinimized == true else { return }
        viewModel?.isMinimized = false
        // Preserve phase during active recording so the expanded view
        // shows the recording placeholder and the pill keeps the waveform.
        if viewModel?.phase != .recording {
            viewModel?.phase = .idle
        }
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

    // MARK: - Phase

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        viewModel?.phase = phase
    }

    // MARK: - Segment Mutations

    /// Appends text to the active segment (follow-up dictation without new capture).
    func appendTextToActiveSegment(_ text: String) {
        guard let viewModel else { return }
        let index = viewModel.activeSegmentIndex
        guard viewModel.segments.indices.contains(index) else { return }
        viewModel.segments[index].text += text
        viewModel.segmentsVersion += 1
        resizePanel()
    }

    /// Inserts a new segment after the active segment (for clipboard captures near cursor).
    func insertSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        let insertIndex = min(viewModel.activeSegmentIndex + 1, viewModel.segments.count)
        viewModel.segments.insert(segment, at: insertIndex)
        viewModel.activeSegmentIndex = insertIndex
        viewModel.segmentsVersion += 1
        resizePanel()
    }

    /// Appends a new segment at the end (for dictation results that should follow chronological order).
    func appendSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        viewModel.segments.append(segment)
        viewModel.activeSegmentIndex = viewModel.segments.count - 1
        viewModel.segmentsVersion += 1
        resizePanel()
    }

    /// Replaces the capture on a specific segment.
    func setCapture(_ capture: CapturedContext, onSegmentAt index: Int) {
        guard let viewModel, viewModel.segments.indices.contains(index) else { return }
        viewModel.segments[index].capture = capture
        viewModel.segmentsVersion += 1
        resizePanel()
    }

    /// Updates segments wholesale.
    func setSegments(_ segments: [InputSegment]) {
        viewModel?.segments = segments
        viewModel?.activeSegmentIndex = max(0, segments.count - 1)
        viewModel?.segmentsVersion += 1
        resizePanel()
    }

    var segmentCount: Int { viewModel?.segments.count ?? 0 }
    var allCaptures: [CapturedContext] { viewModel?.allCaptures ?? [] }
    var fullText: String { viewModel?.fullText ?? "" }

    /// Legacy bridge for CaptureCoordinator code that still uses insertTextAtCursor.
    func insertTextAtCursor(_ text: String) {
        appendTextToActiveSegment(text)
    }

    // MARK: - Conversation Updates

    func startProcessing(inputText: String) {
        let pendingTurn = ConversationTurn(input: inputText, output: "...")
        viewModel?.conversationTurns.append(pendingTurn)
        viewModel?.phase = .processing
        viewModel?.segments = [InputSegment()]
        viewModel?.segmentsVersion += 1
        viewModel?.scrollTrigger += 1
        minimize()
    }

    func finishProcessing(outputText: String) {
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        let lastIndex = viewModel.conversationTurns.count - 1
        let lastTurn = viewModel.conversationTurns[lastIndex]
        viewModel.conversationTurns[lastIndex] = ConversationTurn(id: lastTurn.id, input: lastTurn.input, output: outputText)
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
        guard let viewModel, !viewModel.conversationTurns.isEmpty else { return }
        viewModel.conversationTurns.removeLast()
        viewModel.phase = .idle
        expand()
        Logger.actions.error("Capture panel processing failed: \(message)")
    }

    // MARK: - Captures / Mode Switcher / Destination

    func updateCaptures(_ captures: [CapturedContext]) {
        guard let viewModel else { return }
        // Bridge: set capture on last segment or create new segments
        if captures.isEmpty {
            for i in viewModel.segments.indices {
                viewModel.segments[i].capture = nil
            }
        } else if viewModel.segments.count == 1 && captures.count == 1 {
            viewModel.segments[0].capture = captures[0]
        } else {
            // Rebuild segments preserving existing text in first segment
            let existingText = viewModel.segments.first?.text ?? ""
            var newSegments = [InputSegment(text: existingText, capture: captures.first)]
            for capture in captures.dropFirst() {
                newSegments.append(InputSegment(capture: capture))
            }
            viewModel.segments = newSegments
        }
        viewModel.segmentsVersion += 1
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

    func setProcessedByModeName(_ name: String?) {
        viewModel?.processedByModeName = name
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
        let segs = viewModel?.segments ?? [InputSegment()]
        let newHeight = Self.calculateHeight(for: turns, segments: segs)
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
        let segs = viewModel?.segments ?? [InputSegment()]
        let newHeight = Self.calculateHeight(for: turns, segments: segs)
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

    private static func calculateHeight(for turns: [ConversationTurn], segments: [InputSegment] = [InputSegment()]) -> CGFloat {
        // Segment content height: all segments share one SegmentedTextView,
        // so the minimum height applies to the section total, not per-segment.
        var segmentContentHeight: CGFloat = 0
        for segment in segments {
            let textLines = max(1, CGFloat(segment.text.components(separatedBy: .newlines).count))
            segmentContentHeight += textLines * lineHeight

            if let capture = segment.capture {
                let captureLines = CGFloat(capture.text.components(separatedBy: .newlines).count)
                segmentContentHeight += captureLines * lineHeight * 0.9
                segmentContentHeight += 8 // separator spacing
            }
        }
        let extraHeight = max(segmentSectionMinHeight, segmentContentHeight)

        guard !turns.isEmpty else {
            let total = panelMinBaseHeight + extraHeight + hintBarHeight
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
        let total = panelMinBaseHeight + conversationHeight + extraHeight + hintBarHeight
        return min(total, maxPanelHeight())
    }

    private static let panelMinBaseHeight: CGFloat = 60
    /// Must match CaptureView.segmentTextMinHeight so the panel is tall enough
    /// to show the full segment input section (cursor + capture text).
    private static let segmentSectionMinHeight: CGFloat = 60

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
