import Foundation

struct HotkeySettings: Codable, Equatable {
    var modeSwitcherHotkey: HotkeyBinding
    var toggleRecordingHotkey: HotkeyBinding
    var copyLatestCaptureHotkey: HotkeyBinding
    var cancelRecordingHotkey: HotkeyBinding

    static let `default` = HotkeySettings(
        modeSwitcherHotkey: .unassigned,
        toggleRecordingHotkey: .defaultToggleRecording,
        copyLatestCaptureHotkey: .unassigned,
        cancelRecordingHotkey: .defaultCancelRecording
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

struct VoiceLockSettings: Codable, Equatable {
    var isEnabled: Bool
    var sensitivityThreshold: Float

    static let `default` = VoiceLockSettings(
        isEnabled: false,
        sensitivityThreshold: MFCCSpeakerVerifier.defaultThreshold
    )
}

struct ModeConfiguration: Equatable {
    var modes: [Mode]
    var activeModeID: UUID
    /// Template IDs whose CLI tools are currently available. Not persisted.
    var availableTemplateIDs: Set<String> = []
}
