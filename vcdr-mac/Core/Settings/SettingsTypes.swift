import Foundation

struct HotkeySettings: Codable, Equatable {
    var modeSwitcherHotkey: HotkeyBinding
    var toggleRecordingHotkey: HotkeyBinding
    var copyLatestCaptureHotkey: HotkeyBinding
    var cancelRecordingHotkey: HotkeyBinding

    static let `default` = HotkeySettings(
        modeSwitcherHotkey: .defaultModeSwitcher,
        toggleRecordingHotkey: .defaultToggleRecording,
        copyLatestCaptureHotkey: .unassigned,
        cancelRecordingHotkey: .defaultCancelRecording
    )
}

struct TranscriptionSettings: Codable, Equatable {
    var removeFillerWords: Bool

    static let `default` = TranscriptionSettings(
        removeFillerWords: true
    )
}

struct ModeConfiguration: Equatable {
    var modes: [Mode]
    var activeModeID: UUID
    /// Template IDs whose CLI tools are currently available. Not persisted.
    var availableTemplateIDs: Set<String> = []
}
