import AppKit
import SwiftUI

private enum NavigationLevel: Equatable {
    case modes
    case parameters(modeIndex: Int)
    case options(modeIndex: Int, parameterIndex: Int)
}

final class ModeSwitcherPanel {
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var localEventMonitor: Any?
    private var viewModel: ModeSwitcherViewModel?

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

    func show(
        modes: [Mode],
        activeModeID: UUID,
        outputDestinations: [OutputDestination],
        showHint: Bool,
        parameterOverrides: [UUID: String],
        onSelect: @escaping (UUID) -> Void,
        onOutputDestinationSelect: @escaping (UUID) -> Void,
        onParameterOverride: @escaping (UUID, String) -> Void
    ) {
        hide()

        let activeIndex = modes.firstIndex(where: { $0.id == activeModeID }) ?? 0

        let viewModel = ModeSwitcherViewModel(
            modes: modes,
            highlightedIndex: activeIndex,
            outputDestinations: outputDestinations,
            showHint: showHint,
            parameterOverrides: parameterOverrides,
            onSelect: { [weak self] id in
                onSelect(id)
                self?.hide()
            },
            onOutputDestinationSelect: { [weak self] id in
                onOutputDestinationSelect(id)
                self?.hide()
            },
            onParameterOverride: onParameterOverride,
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let panelHeight = Self.calculateHeight(
            navigationLevel: viewModel.navigationLevel,
            modes: modes,
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
    }

    var isVisible: Bool { panel != nil }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View Model (shared between NSEvent monitor and SwiftUI view)

@Observable
fileprivate final class ModeSwitcherViewModel {
    let modes: [Mode]
    var highlightedIndex: Int
    let outputDestinations: [OutputDestination]
    let showHint: Bool
    let onSelect: (UUID) -> Void
    let onOutputDestinationSelect: (UUID) -> Void
    let onParameterOverride: (UUID, String) -> Void
    let onDismiss: () -> Void

    /// Current navigation level in the mode switcher
    var navigationLevel: NavigationLevel = .modes
    /// Highlighted row index in sub-levels (parameters or options)
    var subHighlightedIndex: Int = 0
    /// Parameter value overrides, keyed by parameter ID -> option value
    var parameterOverrides: [UUID: String]

    /// Whether the destination rows are currently expanded (toggled by "?" key)
    var showingDestinations = false

    /// Callback to notify panel when content height changes (e.g. destinations toggled)
    var onResize: (() -> Void)?

    /// Destination override staged by pressing an activation key.
    /// Applied only when the user confirms with Enter / number key / click on a mode row.
    /// Cleared on Escape (no override applied).
    var pendingDestinationOverrideID: UUID?

    init(
        modes: [Mode],
        highlightedIndex: Int,
        outputDestinations: [OutputDestination],
        showHint: Bool,
        parameterOverrides: [UUID: String],
        onSelect: @escaping (UUID) -> Void,
        onOutputDestinationSelect: @escaping (UUID) -> Void,
        onParameterOverride: @escaping (UUID, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.modes = modes
        self.highlightedIndex = highlightedIndex
        self.outputDestinations = outputDestinations
        self.showHint = showHint
        self.parameterOverrides = parameterOverrides
        self.onSelect = onSelect
        self.onOutputDestinationSelect = onOutputDestinationSelect
        self.onParameterOverride = onParameterOverride
        self.onDismiss = onDismiss
    }

    /// Confirms mode selection and applies any pending destination override.
    func confirmMode(_ id: UUID) {
        if let overrideID = pendingDestinationOverrideID {
            onOutputDestinationSelect(overrideID)
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

        // Escape always dismisses entirely
        if keyCode == 53 {
            onDismiss()
            return true
        }

        switch navigationLevel {
        case .modes:
            return handleModesKeyEvent(keyCode: keyCode, chars: chars, charsIgnoringModifiers: charsIgnoringModifiers)
        case .parameters(let modeIndex):
            return handleParametersKeyEvent(keyCode: keyCode, modeIndex: modeIndex)
        case .options(let modeIndex, let parameterIndex):
            return handleOptionsKeyEvent(keyCode: keyCode, charsIgnoringModifiers: charsIgnoringModifiers, modeIndex: modeIndex, parameterIndex: parameterIndex)
        }
    }

    private func handleModesKeyEvent(keyCode: UInt16, chars: String, charsIgnoringModifiers: String) -> Bool {
        // Toggle destination list with "?" key
        if chars == "?" && !outputDestinations.isEmpty {
            showingDestinations.toggle()
            onResize?()
            return true
        }

        switch keyCode {
        case 125, 38: // Down / J
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case 126, 40: // Up / K
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case 124, 37: // Right arrow / L — drill into parameters
            let mode = modes[highlightedIndex]
            guard !mode.parameters.isEmpty else { return true }
            if mode.parameters.count == 1 {
                navigationLevel = .options(modeIndex: highlightedIndex, parameterIndex: 0)
            } else {
                navigationLevel = .parameters(modeIndex: highlightedIndex)
            }
            subHighlightedIndex = 0
            showingDestinations = false
            onResize?()
            return true
        case 36: // Return
            confirmMode(modes[highlightedIndex].id)
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

    private func handleParametersKeyEvent(keyCode: UInt16, modeIndex: Int) -> Bool {
        let mode = modes[modeIndex]
        let paramCount = mode.parameters.count

        switch keyCode {
        case 125, 38: // Down / J
            subHighlightedIndex = min(subHighlightedIndex + 1, paramCount - 1)
            return true
        case 126, 40: // Up / K
            subHighlightedIndex = max(subHighlightedIndex - 1, 0)
            return true
        case 124, 37, 36: // Right / L / Return — drill into options
            navigationLevel = .options(modeIndex: modeIndex, parameterIndex: subHighlightedIndex)
            subHighlightedIndex = 0
            onResize?()
            return true
        case 123, 4: // Left / H — back to modes
            navigationLevel = .modes
            subHighlightedIndex = 0
            onResize?()
            return true
        default:
            return false
        }
    }

    private func handleOptionsKeyEvent(keyCode: UInt16, charsIgnoringModifiers: String, modeIndex: Int, parameterIndex: Int) -> Bool {
        let mode = modes[modeIndex]
        let parameter = mode.parameters[parameterIndex]
        let optionCount = parameter.options.count

        switch keyCode {
        case 125, 38: // Down / J
            subHighlightedIndex = min(subHighlightedIndex + 1, optionCount - 1)
            return true
        case 126, 40: // Up / K
            subHighlightedIndex = max(subHighlightedIndex - 1, 0)
            return true
        case 36: // Return — select option
            guard subHighlightedIndex < optionCount else { return true }
            let option = parameter.options[subHighlightedIndex]
            parameterOverrides[parameter.id] = option.value
            onParameterOverride(parameter.id, option.value)
            goBackFromOptions(modeIndex: modeIndex)
            return true
        case 123, 4: // Left / H — back without selecting
            goBackFromOptions(modeIndex: modeIndex)
            return true
        default:
            // Number keys 1-9 for direct option selection
            if let number = charsIgnoringModifiers.first?.wholeNumberValue,
               number >= 1, number <= optionCount {
                let option = parameter.options[number - 1]
                parameterOverrides[parameter.id] = option.value
                onParameterOverride(parameter.id, option.value)
                goBackFromOptions(modeIndex: modeIndex)
                return true
            }
            return false
        }
    }

    /// After selecting an option: back to parameter list (multi-param) or mode list (single param)
    func goBackFromOptions(modeIndex: Int) {
        let mode = modes[modeIndex]
        if mode.parameters.count > 1 {
            navigationLevel = .parameters(modeIndex: modeIndex)
        } else {
            navigationLevel = .modes
        }
        subHighlightedIndex = 0
        onResize?()
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
            switch viewModel.navigationLevel {
            case .modes:
                modesContent
            case .parameters(let modeIndex):
                parametersContent(modeIndex: modeIndex)
            case .options(let modeIndex, let parameterIndex):
                optionsContent(modeIndex: modeIndex, parameterIndex: parameterIndex)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private var modesContent: some View {
        ForEach(Array(viewModel.modes.enumerated().prefix(9)), id: \.element.id) { index, mode in
            modeRow(index: index, mode: mode)
                .onHover { hovering in
                    if hovering { viewModel.highlightedIndex = index }
                }
                .onTapGesture { viewModel.confirmMode(mode.id) }
        }

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

            if !mode.parameters.isEmpty {
                parameterIndicator(for: mode)
            }

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

    // MARK: - Parameter Indicator

    private func parameterIndicator(for mode: Mode) -> some View {
        let labels = mode.parameters.compactMap { param -> String? in
            if let overrideValue = viewModel.parameterOverrides[param.id],
               let option = param.options.first(where: { $0.value == overrideValue }) {
                return option.label
            }
            return param.options.first?.label
        }
        let text = labels.joined(separator: ", ")
        return Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    // MARK: - Parameters Content

    private func parametersContent(modeIndex: Int) -> some View {
        let mode = viewModel.modes[modeIndex]
        return VStack(spacing: 2) {
            headerRow(title: mode.name)
            ForEach(Array(mode.parameters.enumerated()), id: \.element.id) { index, parameter in
                parameterRow(index: index, parameter: parameter)
                    .onHover { hovering in
                        if hovering { viewModel.subHighlightedIndex = index }
                    }
                    .onTapGesture {
                        viewModel.navigationLevel = .options(modeIndex: modeIndex, parameterIndex: index)
                        viewModel.subHighlightedIndex = 0
                        viewModel.onResize?()
                    }
            }
        }
    }

    private func parameterRow(index: Int, parameter: ModeParameter) -> some View {
        let isHighlighted = index == viewModel.subHighlightedIndex
        let currentValue = viewModel.parameterOverrides[parameter.id]
            ?? parameter.options.first?.value ?? ""
        let currentLabel = parameter.options.first(where: { $0.value == currentValue })?.label ?? currentValue

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(parameter.name)
                .lineLimit(1)
            Spacer()
            Text(currentLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(isHighlighted ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Options Content

    private func optionsContent(modeIndex: Int, parameterIndex: Int) -> some View {
        let mode = viewModel.modes[modeIndex]
        let parameter = mode.parameters[parameterIndex]
        let selectedValue = viewModel.parameterOverrides[parameter.id]
            ?? parameter.options.first?.value ?? ""

        return VStack(spacing: 2) {
            headerRow(title: parameter.name)
            ForEach(Array(parameter.options.enumerated()), id: \.element.id) { index, option in
                optionRow(index: index, option: option, isSelected: option.value == selectedValue)
                    .onHover { hovering in
                        if hovering { viewModel.subHighlightedIndex = index }
                    }
                    .onTapGesture {
                        viewModel.parameterOverrides[parameter.id] = option.value
                        viewModel.onParameterOverride(parameter.id, option.value)
                        viewModel.goBackFromOptions(modeIndex: modeIndex)
                    }
            }
        }
    }

    private func optionRow(index: Int, option: ModeParameterOption, isSelected: Bool) -> some View {
        let isHighlighted = index == viewModel.subHighlightedIndex
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(option.label)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(isHighlighted ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Header Row

    private func headerRow(title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
