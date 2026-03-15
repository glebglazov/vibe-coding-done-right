/// Computed property accessors that delegate to sub-structs, preserving the original API.
/// All existing call sites (e.g., settings.toggleRecordingHotkey) continue to compile unchanged.
extension AppSettings {
    var modeSwitcherHotkey: HotkeyBinding {
        get { hotkeySettings.modeSwitcherHotkey }
        set { hotkeySettings.modeSwitcherHotkey = newValue }
    }

    var pushToTypeHotkey: HotkeyBinding {
        get { hotkeySettings.pushToTypeHotkey }
        set { hotkeySettings.pushToTypeHotkey = newValue }
    }

    var pushToTypeExpandDelay: Int {
        get { hotkeySettings.pushToTypeExpandDelay }
        set { hotkeySettings.pushToTypeExpandDelay = newValue }
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
}
