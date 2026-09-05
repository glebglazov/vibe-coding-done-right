import AppKit
import OSLog
import SwiftUI

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let hotkeyRegistry: any HotkeyRegistry
    private var navigationKeyClaims: [HotkeyClaim] = []
    private var _viewModel: ModeSwitcherViewModel?

    init(hotkeyRegistry: any HotkeyRegistry) {
        self.hotkeyRegistry = hotkeyRegistry
    }

    /// The current view model, exposed for external updates (e.g., style cycling).
    var viewModel: ModeSwitcherViewModel? { _viewModel }

    // MARK: - Constants

    static let panelWidth: CGFloat = 220
    static let rowHeight: CGFloat = 32
    static let verticalPadding: CGFloat = 10
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    static let headerHeight: CGFloat = 24
    /// Maximum number of modes shown in the quick switcher (keys 1-9)
    static let maxModesInSwitcher = 9
    /// Stored screen positioning state for reuse during resize
    private var screenFrame: NSRect = .zero
    private var menuBarHeight: CGFloat = 0

    @MainActor
    func show(viewModel: ModeSwitcherViewModel) {
        hide()

        let panelHeight = Self.calculateHeight(
            navigationLevel: viewModel.navigation.level,
            modes: viewModel.modes
        )

        let view = ModeSwitcherView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay(hasShadow: true)
        panel.contentView = hostingView

        if let screen = NSScreen.main {
            screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        }
        if let origin = panelOriginBelowMenuBar(width: Self.panelWidth, height: panelHeight, offset: Self.panelOffsetBelowMenuBar) {
            panel.setFrameOrigin(origin)
        }

        // Don't call makeKey() — that would steal focus from the foreground app during recording.
        // Navigation keys are claimed from the system instead of received as a key window's events.
        panel.orderFrontRegardless()
        self.panel = panel
        self._viewModel = viewModel

        // Wire resize callback — recalculate height when navigation level changes
        viewModel.onResize = { [weak self, weak viewModel] in
            guard let self, let viewModel, let panel = self.panel else { return }
            let newHeight = Self.calculateHeight(
                navigationLevel: viewModel.navigation.level,
                modes: viewModel.modes
            )
            let x = self.screenFrame.midX - Self.panelWidth / 2
            let y = self.screenFrame.maxY - self.menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar
            let newFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: newHeight)
            panel.animateResize(to: newFrame)
        }

        claimNavigationKeys()

        // Dismiss if the user clicks outside the panel — go through onDismiss
        // so the coordinator delegate lifecycle (modeSwitcherDidHide) is invoked.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel] _ in
            viewModel?.onDismiss()
        }
    }

    // MARK: - Navigation Keys

    /// Claims every key the switcher navigates by, for as long as it is open.
    ///
    /// The panel never becomes key — that would pull focus off the app the user is
    /// dictating into — so its keys have to be taken from the system rather than
    /// delivered to a key window. Each one is claimed under every modifier state
    /// because the switcher is routinely opened mid-recording, with the
    /// push-to-talk modifiers still held down.
    @MainActor
    private func claimNavigationKeys() {
        navigationKeyClaims = ModeSwitcherViewModel.handledKeyCodes.flatMap { keyCode in
            HotkeyBinding.everyCombination(of: keyCode).compactMap { combination in
                hotkeyRegistry.claim(combination) { [weak self] in
                    _ = self?._viewModel?.handleKey(keyCode: keyCode)
                }
            }
        }
        Logger.hotkeys.info("Mode switcher: claimed \(self.navigationKeyClaims.count) navigation combinations")
    }

    /// Hands every navigation key back to the frontmost app.
    @MainActor
    private func releaseNavigationKeys() {
        for claim in navigationKeyClaims { claim.release() }
        navigationKeyClaims = []
    }

    // MARK: - Height Calculation

    static func calculateHeight(
        navigationLevel: NavigationLevel,
        modes: [Mode]
    ) -> CGFloat {
        switch navigationLevel {
        case .modes:
            let modeRowsHeight = rowHeight * CGFloat(min(modes.count, maxModesInSwitcher))
            return verticalPadding * 2 + modeRowsHeight

        case .parameters(let modeIndex):
            return verticalPadding * 2 + headerHeight + rowHeight * CGFloat(modes[modeIndex].parameters.count)

        case .options(let modeIndex, let parameterIndex):
            return verticalPadding * 2 + headerHeight + rowHeight * CGFloat(modes[modeIndex].parameters[parameterIndex].options.count)
        }
    }

    /// Confirms the currently highlighted mode and hides.
    /// If browsing parameters/options, applies the highlighted option first.
    @MainActor
    func confirmAndHide() {
        if let viewModel = _viewModel {
            // Apply the highlighted option if drilling into parameters
            switch viewModel.navigation.level {
            case .options(let modeIndex, let parameterIndex):
                let parameter = viewModel.modes[modeIndex].parameters[parameterIndex]
                let options = parameter.options
                if viewModel.navigation.subHighlightedIndex < options.count {
                    let option = options[viewModel.navigation.subHighlightedIndex]
                    viewModel.parameterOverrides[parameter.id] = option.value
                    viewModel.onParameterOverride(parameter.id, option.value)
                }
            case .modes, .parameters:
                break
            }

            let mode = viewModel.modes[viewModel.highlightedIndex]
            viewModel.confirmMode(mode.id)
        } else {
            hide()
        }
    }

    @MainActor
    func hide() {
        removeEventMonitor(&eventMonitor)
        releaseNavigationKeys()
        panel?.close()
        panel = nil
        _viewModel = nil
    }

    var isVisible: Bool { panel != nil }

    deinit {
        removeEventMonitor(&eventMonitor)
    }
}
