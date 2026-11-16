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

    // MARK: - Constants

    private static let panelWidth: CGFloat = 480
    static let panelMaxHeightFraction: CGFloat = 0.85
    static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let minimizedPanelWidth: CGFloat = 200
    /// The pill is sized to its content, and a model preparation notice is a
    /// sentence rather than a mode name. At the usual width the assurance that
    /// the recording is safe — the point of the line — would be truncated away.
    private static let minimizedPanelWidthWithNotice: CGFloat = 380
    private static let minimizedPanelHeight: CGFloat = 40

    func show(
        settings: AppSettings,
        overrides: SessionOverrides,
        displayedTurn: DisplayedTurn? = nil,
        outputDestinations: [OutputDestination] = [],
        initialAppName: String? = nil,
        audioRecorder: AudioRecorder? = nil,
        minimized: Bool = false,
        onDismiss: @escaping () -> Void,
        onConfirm: (() -> Void)? = nil,
        onCancelCapture: (() -> Void)? = nil,
        onDestinationSubmit: ((UUID) -> Void)? = nil
    ) {
        tearDown()

        let viewModel = CaptureViewModel(
            settings: settings,
            overrides: overrides,
            displayedTurn: displayedTurn,
            outputDestinations: outputDestinations,
            onDismiss: onDismiss,
            onConfirm: onConfirm,
            onCancelCapture: onCancelCapture,
            onDestinationSubmit: onDestinationSubmit,
            onExpand: { [weak self] in
                self?.expand()
            },
            audioRecorder: audioRecorder
        )
        viewModel.initialAppName = initialAppName
        self.viewModel = viewModel

        presentPanel(viewModel: viewModel, displayedTurn: displayedTurn, skipFocus: minimized)
    }

    func dismiss() {
        tearDown()
    }

    private func tearDown() {
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
    /// Only restores key status when expanded — minimized panels don't need keyboard input
    /// and making them key would steal focus from the foreground app during recording.
    func orderBack() {
        panel?.orderFrontRegardless()
        if !isMinimized {
            panel?.makeKey()
        }
    }

    var isVisible: Bool { panel != nil }

    var isMinimized: Bool { viewModel?.isMinimized ?? false }

    var currentTurn: DisplayedTurn? { viewModel?.displayedTurn }

    private func presentPanel(viewModel: CaptureViewModel, displayedTurn: DisplayedTurn? = nil, skipFocus: Bool = false) {
        let view = CaptureView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: displayedTurn)
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
        if viewModel?.phaseState.phase != .recording && viewModel?.phaseState.phase != .error && viewModel?.phaseState.phase != .processing {
            viewModel?.phaseState.phase = .idle
        }
        if wasMinimized {
            resizePanelToExpanded()
        }
        panel?.makeKey()
    }

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        viewModel?.phaseState.phase = phase
    }

    /// Shows what the transcription model is doing while it holds this run up,
    /// or clears the line once it is ready. Only the notice appearing or going
    /// away resizes the pill — its seconds tick every second, and animating a
    /// resize at that rate would make the pill twitch.
    func setPreparationNotice(_ message: String?) {
        guard let viewModel else { return }
        let hadNotice = viewModel.preparationNotice != nil
        viewModel.preparationNotice = message
        if viewModel.isMinimized, hadNotice != (message != nil) {
            resizePanelToMinimized()
        }
    }

    // MARK: - Panel Resize

    private func resizePanelToMinimized() {
        let width = Self.minimizedWidth(hasPreparationNotice: viewModel?.preparationNotice != nil)
        guard let panel,
              let origin = Self.panelOrigin(width: width, height: Self.minimizedPanelHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: width, height: Self.minimizedPanelHeight))
        panel.animateResize(to: newFrame)
    }

    private static func minimizedWidth(hasPreparationNotice: Bool) -> CGFloat {
        hasPreparationNotice ? minimizedPanelWidthWithNotice : minimizedPanelWidth
    }

    func resizePanelToExpanded() {
        guard let panel, let viewModel else { return }
        let newHeight = Self.calculateHeight(for: viewModel.displayedTurn, hasError: viewModel.phaseState.errorMessage != nil)
        guard let origin = Self.panelOrigin(width: Self.panelWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }

    func resizePanel() {
        guard let panel, let viewModel else { return }
        let newHeight = Self.calculateHeight(for: viewModel.displayedTurn, hasError: viewModel.phaseState.errorMessage != nil)
        let targetWidth = viewModel.isMinimized
            ? Self.minimizedWidth(hasPreparationNotice: viewModel.preparationNotice != nil)
            : Self.panelWidth
        guard let origin = Self.panelOrigin(width: targetWidth, height: newHeight) else { return }
        let newFrame = NSRect(origin: origin, size: NSSize(width: targetWidth, height: newHeight))
        panel.animateResize(to: newFrame)
    }
}
