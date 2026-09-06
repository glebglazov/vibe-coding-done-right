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
    /// The Transcription Model a recording run uses when nothing overrides it.
    /// Per device and never synced: it names a model that has to be installed
    /// here, and another device's answer would name one that is not.
    var defaultModel: TranscriptionModel
    /// What each Transcription Model Family has been told. Kept per family
    /// rather than per app so the settings stay with the family that accepts
    /// them.
    var modelSettings: TranscriptionModelSettingsStore

    static let `default` = TranscriptionSettings(
        removeFillerWords: true,
        defaultModel: .parakeetV3,
        modelSettings: TranscriptionModelSettingsStore()
    )
}

struct ModeConfiguration: Equatable {
    var modes: [Mode]
    var activeModeID: UUID
    /// Template IDs whose CLI tools are currently available. Not persisted.
    var availableTemplateIDs: Set<String> = []
}
