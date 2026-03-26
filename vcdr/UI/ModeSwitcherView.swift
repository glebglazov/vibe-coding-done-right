import SwiftUI

struct ModeSwitcherView: View {
    let viewModel: ModeSwitcherViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let rowCornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 10

    var body: some View {
        VStack(spacing: 2) {
            switch viewModel.navigation.level {
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
            if viewModel.navigation.showingDestinations {
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
                ActiveModeIndicator(color: viewModel.isRecording ? .red : .green)
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
        let keyChar = destination.activationKeyCharacter

        return HStack(spacing: 8) {
            Text(keyChar.isEmpty ? " " : keyChar)
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
                        if hovering { viewModel.navigation.subHighlightedIndex = index }
                    }
                    .onTapGesture {
                        viewModel.navigation.level = .options(modeIndex: modeIndex, parameterIndex: index)
                        viewModel.navigation.subHighlightedIndex = 0
                        viewModel.onResize?()
                    }
            }
        }
    }

    private func parameterRow(index: Int, parameter: ModeParameter) -> some View {
        let isHighlighted = index == viewModel.navigation.subHighlightedIndex
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
                        if hovering { viewModel.navigation.subHighlightedIndex = index }
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
        let isHighlighted = index == viewModel.navigation.subHighlightedIndex
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
