import SwiftUI

// MARK: - Navigation Level

enum NavigationLevel: Equatable {
    case modes
    case parameters(modeIndex: Int)
    case options(modeIndex: Int, parameterIndex: Int)
}

// MARK: - Navigation State

struct NavigationState {
    var level: NavigationLevel = .modes
    var subHighlightedIndex: Int = 0
}

// MARK: - View Model

@Observable
final class ModeSwitcherViewModel {
    let modes: [Mode]
    var highlightedIndex: Int
    var activeModeID: UUID?
    let onSelect: (UUID) -> Void
    /// Activates a mode without dismissing the switcher
    let onActivate: (UUID) -> Void
    @ObservationIgnored var onParameterOverride: (UUID, String) -> Void
    let onDismiss: () -> Void

    /// Navigation state: level and sub-highlighted index
    var navigation = NavigationState()
    /// Parameter value overrides, keyed by parameter ID -> option value.
    /// @ObservationIgnored because changes always coincide with navigation state changes.
    @ObservationIgnored var parameterOverrides: [UUID: String]

    /// Callback to notify panel when content height changes
    @ObservationIgnored var onResize: (() -> Void)?

    /// Whether audio recording is in progress — drives the red recording dot in the view.
    var isRecording: Bool = false

    init(
        modes: [Mode],
        highlightedIndex: Int,
        activeModeID: UUID? = nil,
        parameterOverrides: [UUID: String],
        onSelect: @escaping (UUID) -> Void,
        onActivate: @escaping (UUID) -> Void = { _ in },
        onParameterOverride: @escaping (UUID, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.modes = modes
        self.highlightedIndex = highlightedIndex
        self.activeModeID = activeModeID
        self.parameterOverrides = parameterOverrides
        self.onSelect = onSelect
        self.onActivate = onActivate
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

    /// Returns true if the event was handled
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let charsIgnoringModifiers = event.charactersIgnoringModifiers ?? ""

        if keyCode == KeyCodeMap.escapeKeyCode {
            onDismiss()
            return true
        }

        switch navigation.level {
        case .modes:
            return handleModesKeyEvent(keyCode: keyCode, charsIgnoringModifiers: charsIgnoringModifiers)
        case .parameters(let modeIndex):
            return handleParametersKeyEvent(keyCode: keyCode, modeIndex: modeIndex)
        case .options(let modeIndex, let parameterIndex):
            return handleOptionsKeyEvent(keyCode: keyCode, charsIgnoringModifiers: charsIgnoringModifiers, modeIndex: modeIndex, parameterIndex: parameterIndex)
        }
    }

    private func handleModesKeyEvent(keyCode: UInt16, charsIgnoringModifiers: String) -> Bool {
        switch keyCode {
        case KeyCodeMap.downArrowKeyCode, KeyCodeMap.jKeyCode:
            highlightedIndex = min(highlightedIndex + 1, modes.count - 1)
            return true
        case KeyCodeMap.upArrowKeyCode, KeyCodeMap.kKeyCode:
            highlightedIndex = max(highlightedIndex - 1, 0)
            return true
        case KeyCodeMap.leftArrowKeyCode, KeyCodeMap.hKeyCode:
            onDismiss()
            return true
        case KeyCodeMap.rightArrowKeyCode, KeyCodeMap.lKeyCode:
            let mode = modes[highlightedIndex]
            activateMode(mode.id)
            guard !mode.parameters.isEmpty else {
                return true
            }
            if mode.parameters.count == 1 {
                navigation.level = .options(modeIndex: highlightedIndex, parameterIndex: 0)
            } else {
                navigation.level = .parameters(modeIndex: highlightedIndex)
            }
            navigation.subHighlightedIndex = 0
            onResize?()
            return true
        case KeyCodeMap.returnKeyCode:
            confirmMode(modes[highlightedIndex].id)
            return true
        default:
            // Number keys 1-9 for modes
            if let number = charsIgnoringModifiers.first?.wholeNumberValue,
               number >= 1, number <= modes.count {
                confirmMode(modes[number - 1].id)
                return true
            }
            return false
        }
    }

    private func handleParametersKeyEvent(keyCode: UInt16, modeIndex: Int) -> Bool {
        let mode = modes[modeIndex]
        let paramCount = mode.parameters.count

        switch keyCode {
        case KeyCodeMap.downArrowKeyCode, KeyCodeMap.jKeyCode:
            navigation.subHighlightedIndex = min(navigation.subHighlightedIndex + 1, paramCount - 1)
            return true
        case KeyCodeMap.upArrowKeyCode, KeyCodeMap.kKeyCode:
            navigation.subHighlightedIndex = max(navigation.subHighlightedIndex - 1, 0)
            return true
        case KeyCodeMap.returnKeyCode:
            confirmMode(mode.id)
            return true
        case KeyCodeMap.rightArrowKeyCode, KeyCodeMap.lKeyCode:
            navigation.level = .options(modeIndex: modeIndex, parameterIndex: navigation.subHighlightedIndex)
            navigation.subHighlightedIndex = 0
            onResize?()
            return true
        case KeyCodeMap.leftArrowKeyCode, KeyCodeMap.hKeyCode:
            navigation.level = .modes
            navigation.subHighlightedIndex = 0
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
        case KeyCodeMap.downArrowKeyCode, KeyCodeMap.jKeyCode:
            navigation.subHighlightedIndex = min(navigation.subHighlightedIndex + 1, optionCount - 1)
            return true
        case KeyCodeMap.upArrowKeyCode, KeyCodeMap.kKeyCode:
            navigation.subHighlightedIndex = max(navigation.subHighlightedIndex - 1, 0)
            return true
        case KeyCodeMap.returnKeyCode:
            if navigation.subHighlightedIndex < optionCount {
                let option = parameter.options[navigation.subHighlightedIndex]
                parameterOverrides[parameter.id] = option.value
                onParameterOverride(parameter.id, option.value)
            }
            confirmMode(mode.id)
            return true
        case KeyCodeMap.rightArrowKeyCode, KeyCodeMap.lKeyCode:
            guard navigation.subHighlightedIndex < optionCount else { return true }
            let option = parameter.options[navigation.subHighlightedIndex]
            parameterOverrides[parameter.id] = option.value
            onParameterOverride(parameter.id, option.value)
            goBackFromOptions(modeIndex: modeIndex)
            return true
        case KeyCodeMap.leftArrowKeyCode, KeyCodeMap.hKeyCode:
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
            navigation.level = .parameters(modeIndex: modeIndex)
        } else {
            navigation.level = .modes
        }
        navigation.subHighlightedIndex = 0
        onResize?()
    }
}
