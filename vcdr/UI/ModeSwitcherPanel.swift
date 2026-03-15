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
    static let verticalPadding: CGFloat = 8
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    static let separatorHeight: CGFloat = 17
    static let hintRowHeight: CGFloat = 24
    private static let resizeAnimationDuration: CGFloat = 0.15

    /// Stored screen positioning state for reuse during resize
    private var screenFrame: NSRect = .zero
    private var menuBarHeight: CGFloat = 0

    func show(viewModel: ModeSwitcherViewModel) {
        hide()

        let panelHeight = Self.calculateHeight(
            navigationLevel: viewModel.navigationLevel,
            modes: viewModel.modes,
            destinationCount: viewModel.outputDestinations.count,
            showingDestinations: viewModel.showingDestinations,
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
                navigationLevel: viewModel.navigationLevel,
                modes: viewModel.modes,
                destinationCount: viewModel.outputDestinations.count,
                showingDestinations: viewModel.showingDestinations,
                showHint: viewModel.showHint
            )
            let x = self.screenFrame.midX - Self.panelWidth / 2
            let y = self.screenFrame.maxY - self.menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar
            let newFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: newHeight)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeAnimationDuration
                panel.animator().setFrame(newFrame, display: true)
            }
        }

        // Handle keyboard events via local monitor (works even with nonactivatingPanel + canBecomeKey)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // Dismiss if the user clicks outside the panel
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
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
        let headerHeight: CGFloat = 24

        switch navigationLevel {
        case .modes:
            let modeRowsHeight = rowHeight * CGFloat(min(modes.count, 9))
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

        case .parameters(let modeIndex):
            let paramCount = modes[modeIndex].parameters.count
            return verticalPadding * 2 + headerHeight + rowHeight * CGFloat(paramCount)

        case .options(let modeIndex, let parameterIndex):
            let optionCount = modes[modeIndex].parameters[parameterIndex].options.count
            return verticalPadding * 2 + headerHeight + rowHeight * CGFloat(optionCount)
        }
    }

    /// Confirms the currently highlighted mode (applying any pending destination override) and hides.
    /// If browsing parameters/options, applies the highlighted option first.
    func confirmAndHide() {
        if let viewModel {
            // Apply the highlighted option if drilling into parameters
            switch viewModel.navigationLevel {
            case .options(let modeIndex, let parameterIndex):
                let parameter = viewModel.modes[modeIndex].parameters[parameterIndex]
                let options = parameter.options
                if viewModel.subHighlightedIndex < options.count {
                    let option = options[viewModel.subHighlightedIndex]
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
