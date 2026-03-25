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

    var onCancelCapture: (() -> Void)?

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
        displayedTurn: ConversationTurn? = nil,
        inputSegments: [InputSegment] = [InputSegment()],
        outputDestinations: [OutputDestination] = [],
        initialAppName: String? = nil,
        audioRecorder: AudioRecorder? = nil,
        minimized: Bool = false,
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        tearDown()

        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        let viewModel = CaptureViewModel(
            settings: settings,
            overrides: overrides,
            displayedTurn: displayedTurn,
            inputSegments: inputSegments,
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
        viewModel.initialAppName = initialAppName
        viewModel.onCancelCapture = onCancelCapture
        viewModel.onContentHeightChanged = { [weak self] in
            self?.resizePanel()
        }
        self.viewModel = viewModel

        presentPanel(viewModel: viewModel, displayedTurn: displayedTurn, inputSegments: inputSegments, skipFocus: minimized)
    }

    func hide() {
        tearDown()
    }

    func dismiss() {
        tearDown()
    }

    private func tearDown() {
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

    /// Hides the panel window without tearing down state, so focus can
    /// transfer to another app (e.g. before a paste action).
    func orderOut() {
        panel?.orderOut(nil)
    }

    /// Brings back a panel that was hidden via `orderOut()`.
    func orderBack() {
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    var isVisible: Bool { panel != nil }

    var isMinimized: Bool { viewModel?.isMinimized ?? false }

    var currentText: String? { viewModel?.fullText }

    var currentTurn: ConversationTurn? { viewModel?.displayedTurn }

    private func presentPanel(viewModel: CaptureViewModel, displayedTurn: ConversationTurn? = nil, inputSegments: [InputSegment] = [InputSegment()], skipFocus: Bool = false) {
        let view = CaptureView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: displayedTurn, inputSegments: inputSegments, segmentHeights: viewModel.segmentHeights)
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

        if !skipFocus && !viewModel.isRecording {
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
        if viewModel?.phase != .recording && viewModel?.phase != .error && viewModel?.phase != .processing {
            viewModel?.phase = .idle
        }
        if wasMinimized {
            resizePanelToExpanded()
        }
        if viewModel?.isRecording != true {
            Task { @MainActor [weak self] in
                // Wait for SwiftUI to lay out the expanded hosting view and
                // the resize animation to complete before setting focus.
                // The resize animation is 150ms; this 200ms delay ensures
                // SegmentEditor NSTextViews exist and are in the window.
                try? await Task.sleep(for: Self.expandFocusDelay)
                guard let self,
                      self.isVisible,
                      !self.isMinimized,
                      let contentView = self.panel?.contentView,
                      let panel = self.panel else { return }
                panel.makeKey()
                self.focusActiveTextView(in: contentView, panel: panel)
            }
        } else {
            panel?.makeKey()
        }
    }

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        viewModel?.phase = phase
    }

    private func removeTrailingEmptySegments() {
        guard let viewModel else { return }
        while viewModel.inputSegments.count > 1,
              let last = viewModel.inputSegments.last,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              last.capture == nil {
            viewModel.inputSegments.removeLast()
        }
        viewModel.activeSegmentIndex = min(viewModel.activeSegmentIndex, viewModel.inputSegments.count - 1)
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
        let newHeight = Self.calculateHeight(for: viewModel.displayedTurn, inputSegments: viewModel.inputSegments, segmentHeights: viewModel.segmentHeights, hasError: viewModel.errorMessage != nil)
        guard let origin = Self.panelOrigin(width: Self.panelWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }

    func resizePanel() {
        guard let panel, let viewModel else { return }
        let newHeight = Self.calculateHeight(for: viewModel.displayedTurn, inputSegments: viewModel.inputSegments, segmentHeights: viewModel.segmentHeights, hasError: viewModel.errorMessage != nil)
        // Use explicit target width instead of panel.frame.width — the animator proxy
        // may return intermediate values during resize animations, causing the panel
        // to get stuck at the wrong width (e.g. 200pt minimized width after expanding).
        let targetWidth = viewModel.isMinimized ? Self.minimizedPanelWidth : Self.panelWidth
        guard let origin = Self.panelOrigin(width: targetWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: targetWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }
}
