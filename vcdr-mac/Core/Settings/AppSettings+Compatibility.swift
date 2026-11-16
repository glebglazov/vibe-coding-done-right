import Foundation
import SwiftUI

/// Computed property accessors that delegate to sub-structs, preserving the original API.
/// All existing call sites (e.g., settings.toggleRecordingHotkey) continue to compile unchanged.
extension AppSettings {
    var modes: [Mode] {
        get { modeConfig.modes }
        set { modeConfig.modes = newValue }
    }

    var activeModeID: UUID {
        get { modeConfig.activeModeID }
        set { modeConfig.activeModeID = newValue }
    }

    var modeSwitcherHotkey: HotkeyBinding {
        get { hotkeySettings.modeSwitcherHotkey }
        set { hotkeySettings.modeSwitcherHotkey = newValue }
    }

    var toggleRecordingHotkey: HotkeyBinding {
        get { hotkeySettings.toggleRecordingHotkey }
        set { hotkeySettings.toggleRecordingHotkey = newValue }
    }

    var copyLatestCaptureHotkey: HotkeyBinding {
        get { hotkeySettings.copyLatestCaptureHotkey }
        set { hotkeySettings.copyLatestCaptureHotkey = newValue }
    }

    var cancelRecordingHotkey: HotkeyBinding {
        get { hotkeySettings.cancelRecordingHotkey }
        set { hotkeySettings.cancelRecordingHotkey = newValue }
    }

    var removeFillerWords: Bool {
        get { transcriptionSettings.removeFillerWords }
        set { transcriptionSettings.removeFillerWords = newValue }
    }

    // MARK: - Mode Management

    /// Disables or enables a mode; if the active mode is disabled, switches to the first visible mode.
    func setModeDisabled(_ mode: Mode, disabled: Bool) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index].isDisabled = disabled

        if disabled && activeModeID == mode.id {
            if let firstAvailable = switcherModes.first {
                activeModeID = firstAvailable.id
            }
        }
    }

    /// Deletes a mode; if the active mode is deleted, activates the first remaining mode.
    func deleteMode(_ mode: Mode) {
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == mode.id }
        if activeModeID == mode.id {
            activeModeID = modes.first?.id ?? UUID()
        }
    }

    /// Creates a new mode with a unique name and appends it to the modes list. Returns the new mode's ID.
    @discardableResult
    func addMode() -> UUID {
        let name = nextUniqueName(base: "New Mode", existingNames: Set(modes.map(\.name)))
        let newMode = Mode(id: UUID(), name: name)
        modes.append(newMode)
        return newMode.id
    }

    /// Reorders modes by applying filtered-list move indices back to the full modes array.
    /// `displayedModes` is the filtered subset the user sees; SwiftUI's onMove indices refer to it.
    func moveDisplayedModes(_ displayedModes: [Mode], from source: IndexSet, to destination: Int) {
        var reordered = displayedModes
        reordered.move(fromOffsets: source, toOffset: destination)

        let visibleIDs = Set(reordered.map(\.id))
        var reorderedIterator = reordered.makeIterator()
        modes = modes.map { mode in
            if visibleIDs.contains(mode.id), let next = reorderedIterator.next() {
                return next
            }
            return mode
        }
    }

    /// Resets a template-based mode to its default values.
    func resetModeToDefaults(_ mode: Mode) {
        guard let templateID = mode.templateID,
              let template = ModeTemplate.template(for: templateID),
              let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        template.resetMode(&modes[index])
    }

    // MARK: - Output Destination Management

    /// Returns true if any mode references this destination as its default output.
    func isDestinationInUse(_ destination: OutputDestination) -> Bool {
        modes.contains { $0.defaultOutputDestinationID == destination.id }
    }

    /// Deletes a non-built-in destination that is not in use by any mode.
    func deleteDestination(_ destination: OutputDestination) {
        guard !destination.isBuiltIn, !isDestinationInUse(destination) else { return }
        outputDestinations.removeAll { $0.id == destination.id }
    }

    /// Creates a new bash script destination with a unique name and appends it. Returns the new destination's ID.
    @discardableResult
    func addDestination() -> UUID {
        let name = nextUniqueName(base: "New Destination", existingNames: Set(outputDestinations.map(\.name)))
        let newDest = OutputDestination.makeNewBashScript(name: name)
        outputDestinations.append(newDest)
        return newDest.id
    }

    // MARK: - Variables

    /// Builds the bash-facing environment injected into all bash scripts.
    ///
    /// Each AI Provider's key is injected under its Reserved name (`ANTHROPIC_API_KEY`,
    /// etc.) as a fallback so existing scripts keep working with zero config. An explicit
    /// user Variable overrides its name — but for a Reserved name only a *non-empty* value
    /// overrides; an empty Reserved Variable is treated as unset and falls back to the
    /// Provider key. This is bash-only: the AI-call key always comes from the Provider.
    /// See `docs/adr/0001-ai-provider-key-source-of-truth.md`.
    var variableEnvironment: [String: String] {
        let reserved = Set(AIProvider.allCases.map(\.apiKeyVariableName))
        var env: [String: String] = [:]
        // Provider keys under their Reserved names (the fallback).
        for provider in AIProvider.allCases {
            env[provider.apiKeyVariableName] = apiKey(for: provider)
        }
        // Explicit user variables override; Reserved names only when non-empty.
        for variable in variables where !variable.name.isEmpty {
            if reserved.contains(variable.name) {
                if !variable.value.isEmpty { env[variable.name] = variable.value }
            } else {
                env[variable.name] = variable.value
            }
        }
        return env
    }

    /// The informational notice for a Variables-screen row, or `nil` when the row's
    /// name is not a Reserved Provider key name. Compares the row's override value
    /// against the authoritative Provider key so the UI can explain the relationship.
    /// See `docs/adr/0001-ai-provider-key-source-of-truth.md`.
    func reservedVariableNotice(for variable: Variable) -> ReservedVariableNotice? {
        guard let provider = AIProvider.allCases.first(where: { $0.apiKeyVariableName == variable.name })
        else { return nil }

        if variable.value.isEmpty {
            return .noEffect(provider: provider)
        }
        if variable.value == apiKey(for: provider) {
            return .duplicatesProviderKey(provider: provider)
        }
        return .overridesBashOnly(provider: provider)
    }

    /// Appends a blank Variable and returns its ID, so the caller can send the
    /// user straight to the detail screen that names it.
    @discardableResult
    func addVariable() -> UUID {
        let variable = Variable()
        variables.append(variable)
        return variable.id
    }

    func deleteVariable(_ variable: Variable) {
        variables.removeAll { $0.id == variable.id }
    }

    /// A binding to one Variable by ID, for the detail screen that edits it.
    /// Reading by ID rather than by index keeps the screen standing while the
    /// list under it changes — a removed Variable reads as a blank one until the
    /// screen goes away, instead of indexing past the end.
    func binding(forVariable id: UUID) -> Binding<Variable> {
        Binding(
            get: { [weak self] in
                self?.variables.first { $0.id == id } ?? Variable(id: id)
            },
            set: { [weak self] edited in
                guard let self, let index = variables.firstIndex(where: { $0.id == id }) else { return }
                variables[index] = edited
            }
        )
    }

    /// Set of all defined variable names (for highlighting in command editors).
    /// Reserved names are always defined because the Provider key is injected for them.
    var definedVariableNames: Set<String> {
        Set(variables.map(\.name).filter { !$0.isEmpty })
            .union(AIProvider.allCases.map(\.apiKeyVariableName))
    }
}
