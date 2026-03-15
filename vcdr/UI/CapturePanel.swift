import AppKit
import SwiftUI
import OSLog

@MainActor
final class CapturePanel {
    var panel: NSPanel?
    var viewModel: CaptureViewModel?
    var globalEventMonitor: Any?
    var localEventMonitor: Any?
    var becameKeyObserver: NSObjectProtocol?
    var resignKeyObserver: NSObjectProtocol?

    var onFocusLost: (() -> Void)?

    var onPillClicked: (() -> Void)?

    var onCancelRecording: (() -> Void)?

    var onCancelCapture: (() -> Void)?

    var isLockedForFollowUp = false

    // MARK: - Constants

    private static let panelWidth: CGFloat = 480
    static let panelMaxHeightFraction: CGFloat = 0.85
    static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let minimizedPanelWidth: CGFloat = 200
    private static let minimizedPanelHeight: CGFloat = 40
    private static let expandFocusDelay: Duration = .milliseconds(200)

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
        viewModel.onContentHeightChanged = { [weak self] in
            self?.resizePanel()
        }
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
        removeTrailingEmptySegments()
        removeEventMonitor(&globalEventMonitor)
        removeEventMonitor(&localEventMonitor)
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
        let panelHeight = Self.calculateHeight(for: turns, segments: segments, segmentHeights: viewModel.segmentHeights)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay(hasShadow: true)
        panel.contentView = hostingView

        if let origin = Self.panelOrigin(width: Self.panelWidth, height: panelHeight) {
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        if !viewModel.isRecording {
            focusActiveTextView(in: hostingView, panel: panel)
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
        let wasMinimized = viewModel?.isMinimized == true
        viewModel?.isMinimized = false
        if viewModel?.phase != .recording && viewModel?.phase != .error {
            viewModel?.phase = .idle
        }
        if wasMinimized {
            resizePanelToExpanded()
        }
        panel?.makeKey()
        if viewModel?.isRecording != true {
            // Trigger focus through SwiftUI's own view update mechanism — more reliable than
            // the NSView tree walk when the view hierarchy is being recreated after minimize.
            viewModel?.focusRequest += 1
            Task { @MainActor [weak self] in
                // Wait for SwiftUI to lay out the expanded hosting view
                try? await Task.sleep(for: Self.expandFocusDelay)
                guard let self,
                      self.isVisible,
                      !self.isMinimized,
                      let contentView = self.panel?.contentView,
                      let panel = self.panel else { return }
                self.focusActiveTextView(in: contentView, panel: panel)
            }
        }
    }

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
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

    // MARK: - Panel Resize

    private func resizePanelToMinimized() {
        guard let panel,
              let origin = Self.panelOrigin(width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight))
        panel.animateResize(to: newFrame)
    }

    func resizePanelToExpanded() {
        guard let panel, let viewModel else { return }
        let turns = viewModel.conversationTurns
        let segs = viewModel.segments
        let newHeight = Self.calculateHeight(for: turns, segments: segs, segmentHeights: viewModel.segmentHeights, hasError: viewModel.errorMessage != nil)
        guard let origin = Self.panelOrigin(width: Self.panelWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }

    func resizePanel() {
        guard let panel, let viewModel else { return }
        let turns = viewModel.conversationTurns
        let segs = viewModel.segments
        let newHeight = Self.calculateHeight(for: turns, segments: segs, segmentHeights: viewModel.segmentHeights, hasError: viewModel.errorMessage != nil)
        // Use explicit target width instead of panel.frame.width — the animator proxy
        // may return intermediate values during resize animations, causing the panel
        // to get stuck at the wrong width (e.g. 200pt minimized width after expanding).
        let targetWidth = viewModel.isMinimized ? Self.minimizedPanelWidth : Self.panelWidth
        guard let origin = Self.panelOrigin(width: targetWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: targetWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }
}
