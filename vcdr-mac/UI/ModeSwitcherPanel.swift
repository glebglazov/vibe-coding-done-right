import AppKit
import SwiftUI

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let keyboardTap = EventTapManager()
    private var viewModel: ModeSwitcherViewModel?

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
        // Keyboard events are captured via a CGEvent tap instead of a local event monitor.
        panel.orderFrontRegardless()
        self.panel = panel
        self.viewModel = viewModel

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

        // Intercept keyboard events via CGEvent tap — avoids stealing focus from foreground app.
        // The tap runs on the main thread's run loop, so MainActor.assumeIsolated is safe.
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        _ = keyboardTap.install(
            eventMask: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let panel = Unmanaged<ModeSwitcherPanel>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    panel.keyboardTap.reEnableTap()
                    return Unmanaged.passUnretained(event)
                }
                return MainActor.assumeIsolated {
                    guard let viewModel = panel.viewModel else { return Unmanaged.passUnretained(event) }
                    guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
                    if viewModel.handleKeyEvent(nsEvent) {
                        return nil // consumed
                    }
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        // Dismiss if the user clicks outside the panel — go through onDismiss
        // so the coordinator delegate lifecycle (modeSwitcherDidHide) is invoked.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel] _ in
            viewModel?.onDismiss()
        }
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
    func confirmAndHide() {
        if let viewModel {
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

    func hide() {
        removeEventMonitor(&eventMonitor)
        keyboardTap.uninstall()
        panel?.close()
        panel = nil
        viewModel = nil
    }

    var isVisible: Bool { panel != nil }

    deinit {
        removeEventMonitor(&eventMonitor)
        keyboardTap.uninstall()
    }
}
