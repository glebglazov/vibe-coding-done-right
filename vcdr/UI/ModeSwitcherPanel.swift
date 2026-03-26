import AppKit
import SwiftUI

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var viewModel: ModeSwitcherViewModel?

    // MARK: - Constants

    static let panelWidth: CGFloat = 220
    static let rowHeight: CGFloat = 32
    static let verticalPadding: CGFloat = 10
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    static let separatorHeight: CGFloat = 17
    static let hintRowHeight: CGFloat = 24
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
            modes: viewModel.modes,
            destinationCount: viewModel.outputDestinations.count,
            showingDestinations: viewModel.navigation.showingDestinations,
            showHint: viewModel.showHint
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

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
        self.viewModel = viewModel

        // Wire resize callback — recalculate height when destinations are toggled
        viewModel.onResize = { [weak self, weak viewModel] in
            guard let self, let viewModel, let panel = self.panel else { return }
            let newHeight = Self.calculateHeight(
                navigationLevel: viewModel.navigation.level,
                modes: viewModel.modes,
                destinationCount: viewModel.outputDestinations.count,
                showingDestinations: viewModel.navigation.showingDestinations,
                showHint: viewModel.showHint
            )
            let x = self.screenFrame.midX - Self.panelWidth / 2
            let y = self.screenFrame.maxY - self.menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar
            let newFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: newHeight)
            panel.animateResize(to: newFrame)
        }

        // Handle keyboard events via local monitor (works even with nonactivatingPanel + canBecomeKey)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // Dismiss if the user clicks outside the panel — go through onDismiss
        // so the coordinator delegate lifecycle (modeSwitcherDidHide) is invoked.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel] _ in
            viewModel?.onDismiss()
        }
    }

    // MARK: - Height Calculation

    static func calculateHeight(
        navigationLevel: NavigationLevel,
        modes: [Mode],
        destinationCount: Int,
        showingDestinations: Bool,
        showHint: Bool
    ) -> CGFloat {
        let contentHeight: CGFloat = switch navigationLevel {
        case .modes:
            {
                let modeRowsHeight = rowHeight * CGFloat(min(modes.count, maxModesInSwitcher))
                let hasDestinations = destinationCount > 0

                if !hasDestinations {
                    return verticalPadding * 2 + modeRowsHeight
                }
                if showingDestinations {
                    let destinationRowsHeight = rowHeight * CGFloat(destinationCount)
                    return verticalPadding * 2 + modeRowsHeight + separatorHeight + destinationRowsHeight
                }
                if showHint {
                    return verticalPadding * 2 + modeRowsHeight + separatorHeight + hintRowHeight
                }
                return verticalPadding * 2 + modeRowsHeight
            }()

        case .parameters(let modeIndex):
            verticalPadding * 2 + headerHeight + rowHeight * CGFloat(modes[modeIndex].parameters.count)

        case .options(let modeIndex, let parameterIndex):
            verticalPadding * 2 + headerHeight + rowHeight * CGFloat(modes[modeIndex].parameters[parameterIndex].options.count)
        }

        return contentHeight
    }

    /// Confirms the currently highlighted mode (applying any pending destination override) and hides.
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
        removeEventMonitor(&localEventMonitor)
        panel?.close()
        panel = nil
        viewModel = nil
    }

    var isVisible: Bool { panel != nil }
}
