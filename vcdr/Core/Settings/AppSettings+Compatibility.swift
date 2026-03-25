import Foundation

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

    var availableTemplateIDs: Set<String> {
        get { modeConfig.availableTemplateIDs }
        set { modeConfig.availableTemplateIDs = newValue }
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

    var showModeSwitcherHint: Bool {
        get { hotkeySettings.showModeSwitcherHint }
        set { hotkeySettings.showModeSwitcherHint = newValue }
    }

    var removeFillerWords: Bool {
        get { transcriptionSettings.removeFillerWords }
        set { transcriptionSettings.removeFillerWords = newValue }
    }

    var terminatorTemplateEnabled: Bool {
        get { transcriptionSettings.terminatorTemplateEnabled }
        set { transcriptionSettings.terminatorTemplateEnabled = newValue }
    }

    var terminatorTemplate: String {
        get { transcriptionSettings.terminatorTemplate }
        set { transcriptionSettings.terminatorTemplate = newValue }
    }

    // MARK: - Mode Management

    /// Disables or enables a mode; if the active mode is disabled, switches to the first visible mode.
    func setModeDisabled(_ mode: Mode, disabled: Bool) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index].isDisabled = disabled

        if disabled && activeModeID == mode.id {
            if let firstVisible = visibleModes.first {
                activeModeID = firstVisible.id
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
}
