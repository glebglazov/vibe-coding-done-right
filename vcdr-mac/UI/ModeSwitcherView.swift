import SwiftUI

struct ModeSwitcherView: View {
    let viewModel: ModeSwitcherViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let rowCornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 10
    private static let rowHorizontalPadding: CGFloat = 8
    private static let rowVerticalPadding: CGFloat = 6
    private static let headerVerticalPadding: CGFloat = 4

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
        ForEach(Array(viewModel.modes.enumerated().prefix(ModeSwitcherPanel.maxModesInSwitcher)), id: \.element.id) { index, mode in
            modeRow(index: index, mode: mode)
                .onHover { hovering in
                    if hovering { viewModel.highlightedIndex = index }
                }
                .onTapGesture { viewModel.confirmMode(mode.id) }
        }

        styleIndicator
    }

    // MARK: - Style Indicator

    @ViewBuilder
    private var styleIndicator: some View {
        Divider()
            .padding(.vertical, 4)

        HStack(spacing: 6) {
            Image(systemName: viewModel.isStyleOverridden ? "wand.and.stars" : "sparkles")
                .font(.caption2)
                .foregroundStyle(viewModel.isStyleOverridden ? Color.accentColor : .secondary)

            Text(viewModel.currentStyleName)
                .font(.caption)
                .foregroundStyle(viewModel.isStyleOverridden ? .primary : .secondary)

            if viewModel.isStyleOverridden {
                Text("(overridden)")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.medium)
            }

            Spacer()

            Text("TAB")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.1))
                )
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, 4)
    }

    private func modeRow(index: Int, mode: Mode) -> some View {
        let isHighlighted = index == viewModel.highlightedIndex

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
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.rowCornerRadius)
                .fill(isHighlighted ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Parameter Indicator

    private func parameterIndicator(for mode: Mode) -> some View {
        Text(viewModel.parameterLabel(for: mode))
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
                        viewModel.navigateToParameterOptions(modeIndex: modeIndex, parameterIndex: index)
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
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
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
                        viewModel.selectOption(modeIndex: modeIndex, parameter: parameter, value: option.value)
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
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
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
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.headerVerticalPadding)
    }
}
