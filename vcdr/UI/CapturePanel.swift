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

    var onFocusLost: (() -> Void)?

    var onPillClicked: (() -> Void)?

    var onSubmitText: ((String) -> Void)?

    var onCancelRecording: (() -> Void)?

    var onCancelCapture: (() -> Void)?

    private(set) var isLockedForFollowUp = false

    private static let panelWidth: CGFloat = 480
    private static let panelBaseHeight: CGFloat = 140
    static let panelMaxHeightFraction: CGFloat = 0.85
    static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let minimizedPanelWidth: CGFloat = 200
    private static let minimizedPanelHeight: CGFloat = 40
    private static let expandFocusDelay: Duration = .milliseconds(200)
    private static let textInputHeight: CGFloat = 68

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

    var isVisible: Bool { panel != nil }

    var isMinimized: Bool { viewModel?.isMinimized ?? false }

    var currentText: String? { viewModel?.fullText }

    var currentTurns: [ConversationTurn] { viewModel?.conversationTurns ?? [] }

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

        if let origin = Self.panelOrigin(width: Self.panelWidth, height: panelHeight) {
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        if !viewModel.isRecording {
            Self.focusFirstTextView(in: hostingView, panel: panel)
        }

        setupEventMonitors(panel: panel, hostingView: hostingView)
        Logger.ui.info("Capture panel shown")
    }

    func minimize() {
        guard viewModel?.isMinimized != true else { return }
        viewModel?.isMinimized = true
        resizePanelToMinimized()
        panel?.resignKey()
    }

    func expand() {
        guard viewModel?.isMinimized == true else { return }
        viewModel?.isMinimized = false
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

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        if phase == .recording || phase == .processing {
            removeTrailingEmptySegments()
        }
        viewModel?.phase = phase
    }

    private func removeTrailingEmptySegments() {
        guard let viewModel else { return }
        while viewModel.segments.count > 1,
              let last = viewModel.segments.last,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              last.capture == nil {
            viewModel.segments.removeLast()
        }
        viewModel.activeSegmentIndex = min(viewModel.activeSegmentIndex, viewModel.segments.count - 1)
    }

    func appendTextToActiveSegment(_ text: String) {
        guard let viewModel else { return }
        let index = viewModel.activeSegmentIndex
        guard viewModel.segments.indices.contains(index) else { return }
        viewModel.segments[index].text += text
        resizePanel()
    }

    func insertSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        let insertIndex = min(viewModel.activeSegmentIndex + 1, viewModel.segments.count)
        viewModel.segments.insert(segment, at: insertIndex)
        viewModel.activeSegmentIndex = insertIndex
        resizePanel()
    }

    func appendSegment(_ segment: InputSegment) {
        guard let viewModel else { return }
        viewModel.segments.append(segment)
        viewModel.activeSegmentIndex = viewModel.segments.count - 1
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

    func insertTextAtCursor(_ text: String) {
        appendTextToActiveSegment(text)
    }

    func startProcessing(inputText: String) {
        let captures = viewModel?.allCaptures ?? []
        let pendingTurn = ConversationTurn(input: inputText, output: "...", captures: captures)
        viewModel?.conversationTurns.append(pendingTurn)
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

    func updateCaptures(_ captures: [CapturedContext]) {
        guard let viewModel else { return }
        if captures.isEmpty {
            for i in viewModel.segments.indices {
                viewModel.segments[i].capture = nil
            }
        } else if viewModel.segments.count == 1 && captures.count == 1 {
            viewModel.segments[0].capture = captures[0]
        } else {
            let existingText = viewModel.segments.first?.text ?? ""
            var newSegments = [InputSegment(text: existingText, capture: captures.first)]
            for capture in captures.dropFirst() {
                newSegments.append(InputSegment(capture: capture))
            }
            viewModel.segments = newSegments
        }
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
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    private func resizePanelToMinimized() {
        guard let panel,
              let origin = Self.panelOrigin(width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight))
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func resizePanelToExpanded() {
        guard let panel else { return }
        let turns = viewModel?.conversationTurns ?? []
        let segs = viewModel?.segments ?? [InputSegment()]
        let newHeight = Self.calculateHeight(for: turns, segments: segs)
        guard let origin = Self.panelOrigin(width: Self.panelWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: newHeight))
        panel.setFrame(newFrame, display: true, animate: true)
    }

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

    private static let focusMaxAttempts = 10
    private static let focusRetryDelay: Duration = .milliseconds(10)

    private func setupEventMonitors(panel: NSPanel, hostingView: NSView) {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel, weak panel] event in
            guard let viewModel, panel?.isKeyWindow == true else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak hostingView, weak panel] _ in
            guard let self else { return }
            if self.viewModel?.isMinimized == true {
                guard self.viewModel?.isRecording != true else { return }
                self.onPillClicked?()
                return
            }
            guard let hostingView, let panel else { return }
            if self.viewModel?.isRecording != true {
                Self.focusFirstTextView(in: hostingView, panel: panel)
            }
        }

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

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isLockedForFollowUp else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }
    }

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
