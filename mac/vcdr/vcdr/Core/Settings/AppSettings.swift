import Foundation
import CoreGraphics
import OSLog

enum PostTranscriptionActionType: String, CaseIterable, Codable {
    case paste = "paste"
    case bash = "bash"
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let unassigned = HotkeyBinding(keyCode: 0, modifiers: 0)

    /// Default push-to-talk: Cmd+Option+Space
    static let defaultPushToTalk = HotkeyBinding(
        keyCode: 49,
        modifiers: UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
    )

    var isAssigned: Bool {
        keyCode != 0 || modifiers != 0
    }
}

@Observable
final class AppSettings {
    var pushToTalkHotkey: HotkeyBinding {
        didSet { save() }
    }
    var modeSwitcherHotkey: HotkeyBinding {
        didSet { save() }
    }
    var modes: [Mode] {
        didSet { save() }
    }
    var activeModeID: UUID {
        didSet { save() }
    }
    /// Selected input device unique ID, or nil for system default
    var preferredInputDeviceID: String? {
        didSet { save() }
    }

    /// Active mode looked up by ID, falling back to first mode
    var activeMode: Mode {
        modes.first(where: { $0.id == activeModeID }) ?? modes.first ?? Mode.makeDefault()
    }

    private let userDefaults: UserDefaults

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let pushToTalkHotkey = "pushToTalkHotkey"
        static let modeSwitcherHotkey = "modeSwitcherHotkey"
        static let modes = "modes"
        static let activeModeID = "activeModeID"
        static let preferredInputDeviceID = "preferredInputDeviceID"
        // Legacy keys for migration
        static let legacyKeyCode = "hotkeyKeyCode"
        static let legacyModifiers = "hotkeyModifiers"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load push-to-talk hotkey (with migration from legacy keys)
        if let data = userDefaults.data(forKey: Keys.pushToTalkHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.pushToTalkHotkey = decoded
        } else {
            // Migrate from legacy keys
            let savedKeyCode = userDefaults.integer(forKey: Keys.legacyKeyCode)
            let savedModifiers = userDefaults.integer(forKey: Keys.legacyModifiers)
            if savedKeyCode != 0 || savedModifiers != 0 {
                self.pushToTalkHotkey = HotkeyBinding(
                    keyCode: UInt16(savedKeyCode),
                    modifiers: UInt64(savedModifiers)
                )
            } else {
                self.pushToTalkHotkey = .defaultPushToTalk
            }
        }

        // Load mode switcher hotkey (default: unassigned)
        if let data = userDefaults.data(forKey: Keys.modeSwitcherHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data) {
            self.modeSwitcherHotkey = decoded
        } else {
            self.modeSwitcherHotkey = .unassigned
        }

        // Load modes into local var first (can't use self.modes before all properties init)
        let loadedModes: [Mode]
        if let modesData = userDefaults.data(forKey: Keys.modes),
           let decoded = try? JSONDecoder().decode([Mode].self, from: modesData),
           !decoded.isEmpty {
            loadedModes = decoded
        } else {
            let oldActionType = PostTranscriptionActionType(
                rawValue: userDefaults.string(forKey: "actionType") ?? ""
            ) ?? .paste
            let oldBashCommand = userDefaults.string(forKey: "bashCommand") ?? "echo {}"
            loadedModes = [Mode(
                id: UUID(),
                name: "Default",
                actionType: oldActionType,
                bashCommand: oldBashCommand
            )]
        }
        self.modes = loadedModes

        // Load active mode ID, defaulting to first mode
        if let savedActiveID = userDefaults.string(forKey: Keys.activeModeID),
           let uuid = UUID(uuidString: savedActiveID) {
            self.activeModeID = uuid
        } else {
            self.activeModeID = loadedModes.first?.id ?? UUID()
        }

        self.preferredInputDeviceID = userDefaults.string(forKey: Keys.preferredInputDeviceID)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(pushToTalkHotkey) {
            userDefaults.set(encoded, forKey: Keys.pushToTalkHotkey)
        }
        if let encoded = try? JSONEncoder().encode(modeSwitcherHotkey) {
            userDefaults.set(encoded, forKey: Keys.modeSwitcherHotkey)
        }
        userDefaults.set(activeModeID.uuidString, forKey: Keys.activeModeID)
        if let encoded = try? JSONEncoder().encode(modes) {
            userDefaults.set(encoded, forKey: Keys.modes)
        }
        if let preferredInputDeviceID {
            userDefaults.set(preferredInputDeviceID, forKey: Keys.preferredInputDeviceID)
        } else {
            userDefaults.removeObject(forKey: Keys.preferredInputDeviceID)
        }
        Logger.settings.info("Settings saved")
    }
}
