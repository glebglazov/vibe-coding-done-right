import AppKit
import SwiftUI

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?

    /// Called when the panel is hidden (by any dismiss path: selection, escape, click outside, toggle).
    var onHide: (() -> Void)?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 32
    private static let verticalPadding: CGFloat = 8
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let separatorHeight: CGFloat = 17
    private static let hintRowHeight: CGFloat = 24
    private static let resizeAnimationDuration: CGFloat = 0.15

    /// Vertical offset so the mode switcher always appears below where the recording
    /// indicator circle and mode label sit (8pt menu bar gap + 44pt circle + 4pt spacing
    /// + ~16pt label + 8pt spacing), ensuring a consistent position whether recording
    /// is active or not.
    private static let recordingIndicatorClearance: CGFloat = 80

    /// Stored screen positioning state for reuse during resize
    private var screenFrame: NSRect = .zero
    private var menuBarHeight: CGFloat = 0

    /// Stored reference to the view model so we can inspect pending override state on dismiss.
    private var viewModel: ModeSwitcherViewModel?

    /// Raw callback for clearing override on non-confirmed dismiss (avoids re-entrant hide).
    private var onDismissOverrideClear: (() -> Void)?

    func show(
        modes: [Mode],
        activeModeID: UUID,
        outputDestinations: [OutputDestination],
        showHint: Bool,
        currentOutputDestinationOverrideID: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onOutputDestinationSelect: @escaping (UUID?) -> Void
    ) {
        hide()

        let activeIndex = modes.firstIndex(where: { $0.id == activeModeID }) ?? 0

        // Store raw callback for dismiss path (does not call hide)
        self.onDismissOverrideClear = { onOutputDestinationSelect(nil) }

        let viewModel = ModeSwitcherViewModel(
            modes: modes,
            activeModeID: activeModeID,
            highlightedIndex: activeIndex,
            outputDestinations: outputDestinations,
            showHint: showHint,
            initialOverrideID: currentOutputDestinationOverrideID,
            onSelect: { [weak self] id in
                onSelect(id)
                self?.hide()
            },
            onOutputDestinationSelect: { [weak self] id in
                onOutputDestinationSelect(id)
                self?.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        self.viewModel = viewModel

        let panelHeight = Self.calculateHeight(
            modeCount: modes.count,
            destinationCount: outputDestinations.count,
            showingDestinations: viewModel.showingDestinations,
            showHint: showHint
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

        if let screen = NSScreen.main {
            screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.panelWidth / 2
            let y = screenFrame.maxY - menuBarHeight - panelHeight - Self.panelOffsetBelowMenuBar - Self.recordingIndicatorClearance
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        // Wire resize callback — recalculate height when destinations are toggled
        viewModel.onResize = { [weak self, weak viewModel] in
            guard let self, let viewModel, let panel = self.panel else { return }
            let newHeight = Self.calculateHeight(
                modeCount: viewModel.modes.count,
                destinationCount: viewModel.outputDestinations.count,
                showingDestinations: viewModel.showingDestinations,
                showHint: viewModel.showHint
            )
            let x = self.screenFrame.midX - Self.panelWidth / 2
            let y = self.screenFrame.maxY - self.menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar - Self.recordingIndicatorClearance
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

    private static func calculateHeight(
        modeCount: Int,
        destinationCount: Int,
        showingDestinations: Bool,
        showHint: Bool
    ) -> CGFloat {
        let modeRowsHeight = rowHeight * CGFloat(modeCount)
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
    }

    func hide() {
        let wasVisible = panel != nil

        // If dismissed without confirming and the user changed the pending override,
        // clear the override entirely (user staged a change but didn't commit it).
        if let viewModel, !viewModel.wasConfirmed,
           viewModel.pendingDestinationOverrideID != viewModel.initialOverrideID {
            onDismissOverrideClear?()
        }

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
        viewModel = nil
        onDismissOverrideClear = nil
        if wasVisible {
            onHide?()
        }
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
    let activeModeID: UUID
    var highlightedIndex: Int
    let outputDestinations: [OutputDestination]
    let showHint: Bool
    let onSelect: (UUID) -> Void
    let onOutputDestinationSelect: (UUID?) -> Void
    let onDismiss: () -> Void

    /// Whether the destination rows are currently expanded (toggled by "?" key).
    /// Auto-expanded when reopening with an active override so the user can see it.
    var showingDestinations: Bool

    /// Callback to notify panel when content height changes (e.g. destinations toggled)
    var onResize: (() -> Void)?

    /// The override that was active when the panel opened.
    /// Used to detect whether the user changed the override on dismiss.
    let initialOverrideID: UUID?

    /// Destination override staged by pressing an activation key.
    /// Applied when the user confirms with Enter / number key / click on a mode row.
    var pendingDestinationOverrideID: UUID?

    /// Set to true when the user confirms via Enter / number / click,
    /// so hide() knows not to fire the dismiss-clear logic.
    var wasConfirmed = false

    init(
        modes: [Mode],
        activeModeID: UUID,
        highlightedIndex: Int,
        outputDestinations: [OutputDestination],
        showHint: Bool,
        initialOverrideID: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onOutputDestinationSelect: @escaping (UUID?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.modes = modes
        self.activeModeID = activeModeID
        self.highlightedIndex = highlightedIndex
        self.outputDestinations = outputDestinations
        self.showHint = showHint
        self.initialOverrideID = initialOverrideID
        self.pendingDestinationOverrideID = initialOverrideID
        self.showingDestinations = initialOverrideID != nil
        self.onSelect = onSelect
        self.onOutputDestinationSelect = onOutputDestinationSelect
        self.onDismiss = onDismiss
    }

    /// Confirms mode selection and applies the pending destination override.
    func confirmMode(_ id: UUID) {
        wasConfirmed = true
        if id == activeModeID {
            // Same mode — apply override change (nil clears the override)
            onOutputDestinationSelect(pendingDestinationOverrideID)
        } else {
            // Different mode — clear any override
            onOutputDestinationSelect(nil)
        }
        onSelect(id)
    }

    /// Toggles the pending destination override. Pressing the same key twice clears it.
    func toggleDestinationOverride(_ id: UUID) {
        if pendingDestinationOverrideID == id {
            pendingDestinationOverrideID = nil
        } else {
            pendingDestinationOverrideID = id
        }
    }

    /// Returns true if the event was handled
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let charsIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        // Use `characters` (not `charactersIgnoringModifiers`) to detect "?" which is Shift+/
        let chars = event.characters ?? ""

        // Toggle destination list with "?" key
        if chars == "?" && !outputDestinations.isEmpty {
            showingDestinations.toggle()
            onResize?()
            return true
        }

        switch keyCode {
        case 125, 38: // Down arrow, J
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case 126, 40: // Up arrow, K
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case 36: // Return
            confirmMode(modes[highlightedIndex].id)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            // Number keys 1-9 for modes
            if let number = charsIgnoringModifiers.first?.wholeNumberValue,
               number >= 1, number <= modes.count {
                confirmMode(modes[number - 1].id)
                return true
            }
            // Output destination activation keys — stage as pending override
            if let char = charsIgnoringModifiers.first {
                let key = String(char)
                if let destination = outputDestinations.first(where: { $0.activationKey == key }) {
                    toggleDestinationOverride(destination.id)
                    return true
                }
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
            // Modes section
            ForEach(Array(viewModel.modes.enumerated().prefix(9)), id: \.element.id) { index, mode in
                modeRow(index: index, mode: mode)
                    .onHover { hovering in
                        if hovering { viewModel.highlightedIndex = index }
                    }
                    .onTapGesture { viewModel.confirmMode(mode.id) }
            }

            // Output destinations section (conditional)
            if !viewModel.outputDestinations.isEmpty {
                if viewModel.showingDestinations {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(viewModel.outputDestinations) { destination in
                        destinationRow(destination: destination)
                            .onTapGesture {
                                viewModel.toggleDestinationOverride(destination.id)
                            }
                    }
                } else if viewModel.showHint {
                    Divider()
                        .padding(.vertical, 4)

                    Text("Press ? for output options")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    private func modeRow(index: Int, mode: Mode) -> some View {
        let isHighlighted = index == viewModel.highlightedIndex
        let defaultDestination = viewModel.outputDestinations.first(where: { $0.id == mode.defaultOutputDestinationID })
        // On the highlighted row, show the pending override symbol if one is staged
        let overrideDestination = isHighlighted
            ? viewModel.pendingDestinationOverrideID.flatMap { overrideID in
                viewModel.outputDestinations.first(where: { $0.id == overrideID })
            }
            : nil
        let displayedDestination = overrideDestination ?? defaultDestination

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(mode.name)
                .lineLimit(1)

            Spacer()

            Text(displayedDestination?.symbol ?? "")
                .font(.caption)
                .foregroundStyle(overrideDestination != nil ? .white : .primary)
                .padding(.horizontal, overrideDestination != nil ? 4 : 0)
                .padding(.vertical, overrideDestination != nil ? 2 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(overrideDestination != nil ? Color.accentColor : .clear)
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(isHighlighted ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func destinationRow(destination: OutputDestination) -> some View {
        let isSelected = viewModel.pendingDestinationOverrideID == destination.id

        return HStack(spacing: 8) {
            Text(destination.activationKey.isEmpty ? " " : destination.activationKey)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(destination.symbol)

            Text(destination.name)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
