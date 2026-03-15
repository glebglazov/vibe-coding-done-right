import Foundation

struct HotkeySettings: Codable, Equatable {
    var modeSwitcherHotkey: HotkeyBinding
    var pushToTypeHotkey: HotkeyBinding
    var pushToTypeExpandDelay: Int
    var toggleRecordingHotkey: HotkeyBinding
    var copyLatestCaptureHotkey: HotkeyBinding
    var cancelRecordingHotkey: HotkeyBinding
    var showModeSwitcherHint: Bool

    static let `default` = HotkeySettings(
        modeSwitcherHotkey: .unassigned,
        pushToTypeHotkey: .unassigned,
        pushToTypeExpandDelay: AppSettings.defaultPushToTypeExpandDelay,
        toggleRecordingHotkey: .defaultToggleRecording,
        copyLatestCaptureHotkey: .unassigned,
        cancelRecordingHotkey: .defaultCancelRecording,
        showModeSwitcherHint: true
    )
}

struct TranscriptionSettings: Codable, Equatable {
    var removeFillerWords: Bool
    var terminatorTemplateEnabled: Bool
    var terminatorTemplate: String

    static let `default` = TranscriptionSettings(
        removeFillerWords: true,
        terminatorTemplateEnabled: true,
        terminatorTemplate: Mode.defaultTerminatorTemplate
    )
}

struct ModeConfiguration: Equatable {
    var modes: [Mode]
    var activeModeID: UUID
    /// Template IDs whose CLI tools are currently available. Not persisted.
    var availableTemplateIDs: Set<String> = []
}
