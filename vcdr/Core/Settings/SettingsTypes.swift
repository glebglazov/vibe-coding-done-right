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
        pushToTypeExpandDelay: 500,
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
