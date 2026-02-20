import AppKit
import SwiftUI

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 32
    private static let verticalPadding: CGFloat = 8
    private static let panelOffsetBelowMenuBar: CGFloat = 8

    func show(modes: [Mode], activeModeID: UUID, onSelect: @escaping (UUID) -> Void) {
        hide()

        let activeIndex = modes.firstIndex(where: { $0.id == activeModeID }) ?? 0
        let panelHeight = Self.verticalPadding * 2 + Self.rowHeight * CGFloat(modes.count)

        let viewModel = ModeSwitcherViewModel(
            modes: modes,
            highlightedIndex: activeIndex,
            onSelect: { [weak self] id in
                onSelect(id)
                self?.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Position at top center, just below the menu bar (same as recording indicator)
        if let screen = NSScreen.main {
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

    func hide() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel != nil }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View Model (shared between NSEvent monitor and SwiftUI view)

@Observable
private final class ModeSwitcherViewModel {
    let modes: [Mode]
    var highlightedIndex: Int
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void

    init(modes: [Mode], highlightedIndex: Int, onSelect: @escaping (UUID) -> Void, onDismiss: @escaping () -> Void) {
        self.modes = modes
        self.highlightedIndex = highlightedIndex
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    /// Returns true if the event was handled
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let chars = event.charactersIgnoringModifiers ?? ""

        switch keyCode {
        case 125, 38: // Down arrow, J
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case 126, 40: // Up arrow, K
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case 36: // Return
            onSelect(modes[highlightedIndex].id)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            // Number keys 1-9
            if let number = chars.first?.wholeNumberValue,
               number >= 1, number <= modes.count {
                onSelect(modes[number - 1].id)
                return true
            }
            return false
        }
    }
}

// MARK: - SwiftUI View

private struct ModeSwitcherView: View {
    let viewModel: ModeSwitcherViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let rowCornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 6

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(viewModel.modes.enumerated().prefix(9)), id: \.element.id) { index, mode in
                modeRow(index: index, mode: mode)
                    .onHover { hovering in
                        if hovering { viewModel.highlightedIndex = index }
                    }
                    .onTapGesture { viewModel.onSelect(mode.id) }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    private func modeRow(index: Int, mode: Mode) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(mode.name)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(index == viewModel.highlightedIndex ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
