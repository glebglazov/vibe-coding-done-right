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

// MARK: - Navigation State

struct NavigationState {
    var level: NavigationLevel = .modes
    var subHighlightedIndex: Int = 0
    var showingDestinations = false
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
    @ObservationIgnored var onParameterOverride: (UUID, String) -> Void
    let onDismiss: () -> Void

    /// Navigation state: level, sub-highlighted index, and destination visibility
    var navigation = NavigationState()
    /// Parameter value overrides, keyed by parameter ID -> option value.
    /// @ObservationIgnored because changes always coincide with navigation state changes.
    @ObservationIgnored var parameterOverrides: [UUID: String]

    /// Callback to notify panel when content height changes (e.g. destinations toggled)
    @ObservationIgnored var onResize: (() -> Void)?

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

        switch navigation.level {
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
            navigation.showingDestinations.toggle()
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
                navigation.level = .options(modeIndex: highlightedIndex, parameterIndex: 0)
            } else {
                navigation.level = .parameters(modeIndex: highlightedIndex)
            }
            navigation.subHighlightedIndex = 0
            navigation.showingDestinations = false
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
            // Output destination activation keys (bare key matching via keyCode-derived character)
            if let char = charsIgnoringModifiers.first {
                let key = String(char).uppercased()
                if let destination = outputDestinations.first(where: { $0.activationKeyCharacter.uppercased() == key }) {
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
            navigation.subHighlightedIndex = min(navigation.subHighlightedIndex + 1, paramCount - 1)
            return true
        case KeyCode.upArrow, KeyCode.k:
            navigation.subHighlightedIndex = max(navigation.subHighlightedIndex - 1, 0)
            return true
        case KeyCode.returnKey:
            confirmMode(mode.id)
            return true
        case KeyCode.rightArrow, KeyCode.l:
            navigation.level = .options(modeIndex: modeIndex, parameterIndex: navigation.subHighlightedIndex)
            navigation.subHighlightedIndex = 0
            onResize?()
            return true
        case KeyCode.leftArrow, KeyCode.h:
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
        case KeyCode.downArrow, KeyCode.j:
            navigation.subHighlightedIndex = min(navigation.subHighlightedIndex + 1, optionCount - 1)
            return true
        case KeyCode.upArrow, KeyCode.k:
            navigation.subHighlightedIndex = max(navigation.subHighlightedIndex - 1, 0)
            return true
        case KeyCode.returnKey:
            if navigation.subHighlightedIndex < optionCount {
                let option = parameter.options[navigation.subHighlightedIndex]
                parameterOverrides[parameter.id] = option.value
                onParameterOverride(parameter.id, option.value)
            }
            confirmMode(mode.id)
            return true
        case KeyCode.rightArrow, KeyCode.l:
            guard navigation.subHighlightedIndex < optionCount else { return true }
            let option = parameter.options[navigation.subHighlightedIndex]
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
            navigation.level = .parameters(modeIndex: modeIndex)
        } else {
            navigation.level = .modes
        }
        navigation.subHighlightedIndex = 0
        onResize?()
    }
}
