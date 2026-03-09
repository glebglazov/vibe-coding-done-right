import SwiftUI

// MARK: - Navigation Level

enum NavigationLevel: Equatable {
    case modes
    case parameters(modeIndex: Int)
    case options(modeIndex: Int, parameterIndex: Int)
}

// MARK: - Key Codes

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let h: UInt16 = 4
    static let j: UInt16 = 38
    static let k: UInt16 = 40
    static let l: UInt16 = 37
}

// MARK: - View Model

@Observable
final class ModeSwitcherViewModel {
    let modes: [Mode]
    var highlightedIndex: Int
    var activeModeID: UUID?
    let outputDestinations: [OutputDestination]
    let showHint: Bool
    let onSelect: (UUID) -> Void
    /// Activates a mode without dismissing the switcher
    let onActivate: (UUID) -> Void
    let onOutputDestinationSelect: (UUID?) -> Void
    var onParameterOverride: (UUID, String) -> Void
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

    /// Active destination override, applied immediately when toggled.
    /// Shown on all mode rows (not just highlighted) since it's already in effect.
    var activeDestinationOverrideID: UUID?

    init(
        modes: [Mode],
        highlightedIndex: Int,
        activeModeID: UUID? = nil,
        outputDestinations: [OutputDestination],
        showHint: Bool,
        parameterOverrides: [UUID: String],
        activeDestinationOverrideID: UUID? = nil,
        onSelect: @escaping (UUID) -> Void,
        onActivate: @escaping (UUID) -> Void = { _ in },
        onOutputDestinationSelect: @escaping (UUID?) -> Void,
        onParameterOverride: @escaping (UUID, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.modes = modes
        self.highlightedIndex = highlightedIndex
        self.activeModeID = activeModeID
        self.outputDestinations = outputDestinations
        self.showHint = showHint
        self.parameterOverrides = parameterOverrides
        self.activeDestinationOverrideID = activeDestinationOverrideID
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onOutputDestinationSelect = onOutputDestinationSelect
        self.onParameterOverride = onParameterOverride
        self.onDismiss = onDismiss
    }

    /// Confirms mode selection and dismisses.
    func confirmMode(_ id: UUID) {
        onSelect(id)
    }

    /// Activates a mode without dismissing the switcher.
    func activateMode(_ id: UUID) {
        activeModeID = id
        onActivate(id)
    }

    /// Toggles a destination override immediately. Pressing the same key twice clears it.
    func toggleDestinationOverride(_ id: UUID) {
        if activeDestinationOverrideID == id {
            activeDestinationOverrideID = nil
            onOutputDestinationSelect(nil)
        } else {
            activeDestinationOverrideID = id
            onOutputDestinationSelect(id)
        }
    }

    /// Returns true if the event was handled
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let charsIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        // Use `characters` (not `charactersIgnoringModifiers`) to detect "?" which is Shift+/
        let chars = event.characters ?? ""

        if keyCode == KeyCode.escape {
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
        case KeyCode.downArrow, KeyCode.j:
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case KeyCode.upArrow, KeyCode.k:
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case KeyCode.leftArrow, KeyCode.h:
            onDismiss()
            return true
        case KeyCode.rightArrow, KeyCode.l:
            let mode = modes[highlightedIndex]
            activateMode(mode.id)
            guard !mode.parameters.isEmpty else {
                return true
            }
            if mode.parameters.count == 1 {
                navigationLevel = .options(modeIndex: highlightedIndex, parameterIndex: 0)
            } else {
                navigationLevel = .parameters(modeIndex: highlightedIndex)
            }
            subHighlightedIndex = 0
            showingDestinations = false
            onResize?()
            return true
        case KeyCode.returnKey:
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
        case KeyCode.downArrow, KeyCode.j:
            subHighlightedIndex = min(subHighlightedIndex + 1, paramCount - 1)
            return true
        case KeyCode.upArrow, KeyCode.k:
            subHighlightedIndex = max(subHighlightedIndex - 1, 0)
            return true
        case KeyCode.returnKey:
            confirmMode(mode.id)
            return true
        case KeyCode.rightArrow, KeyCode.l:
            navigationLevel = .options(modeIndex: modeIndex, parameterIndex: subHighlightedIndex)
            subHighlightedIndex = 0
            onResize?()
            return true
        case KeyCode.leftArrow, KeyCode.h:
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
        case KeyCode.downArrow, KeyCode.j:
            subHighlightedIndex = min(subHighlightedIndex + 1, optionCount - 1)
            return true
        case KeyCode.upArrow, KeyCode.k:
            subHighlightedIndex = max(subHighlightedIndex - 1, 0)
            return true
        case KeyCode.returnKey:
            if subHighlightedIndex < optionCount {
                let option = parameter.options[subHighlightedIndex]
                parameterOverrides[parameter.id] = option.value
                onParameterOverride(parameter.id, option.value)
            }
            confirmMode(mode.id)
            return true
        case KeyCode.rightArrow, KeyCode.l:
            guard subHighlightedIndex < optionCount else { return true }
            let option = parameter.options[subHighlightedIndex]
            parameterOverrides[parameter.id] = option.value
            onParameterOverride(parameter.id, option.value)
            goBackFromOptions(modeIndex: modeIndex)
            return true
        case KeyCode.leftArrow, KeyCode.h:
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

struct ModeSwitcherView: View {
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
        // Show active override on all rows since it's already applied
        let overrideDestination = viewModel.activeDestinationOverrideID.flatMap { overrideID in
            viewModel.outputDestinations.first(where: { $0.id == overrideID })
        }
        let displayedDestination = overrideDestination ?? defaultDestination

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(mode.name)
                .lineLimit(1)

            if mode.id == viewModel.activeModeID {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.8), radius: 4)
                    .shadow(color: .green.opacity(0.4), radius: 8)
            }

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
        let isSelected = viewModel.activeDestinationOverrideID == destination.id

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
