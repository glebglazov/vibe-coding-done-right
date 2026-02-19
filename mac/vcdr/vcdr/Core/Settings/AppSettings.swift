import Foundation
import CoreGraphics
import OSLog

enum PostTranscriptionActionType: String, CaseIterable, Codable {
    case paste = "paste"
    case bash = "bash"
}

@Observable
final class AppSettings {
    var hotkeyKeyCode: UInt16 {
        didSet { save() }
    }
    var hotkeyModifiers: UInt64 {
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Default hotkey: Cmd+Option+Space (keyCode 49 = Space)
        let savedKeyCode = userDefaults.integer(forKey: "hotkeyKeyCode")
        self.hotkeyKeyCode = savedKeyCode != 0 ? UInt16(savedKeyCode) : 49

        let savedModifiers = userDefaults.integer(forKey: "hotkeyModifiers")
        if savedModifiers != 0 {
            self.hotkeyModifiers = UInt64(savedModifiers)
        } else {
            self.hotkeyModifiers = UInt64(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
        }

        // Load modes into local var first (can't use self.modes before all properties init)
        let loadedModes: [Mode]
        if let modesData = userDefaults.data(forKey: "modes"),
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
        if let savedActiveID = userDefaults.string(forKey: "activeModeID"),
           let uuid = UUID(uuidString: savedActiveID) {
            self.activeModeID = uuid
        } else {
            self.activeModeID = loadedModes.first?.id ?? UUID()
        }

        self.preferredInputDeviceID = userDefaults.string(forKey: "preferredInputDeviceID")
    }

    private func save() {
        userDefaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        userDefaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        userDefaults.set(activeModeID.uuidString, forKey: "activeModeID")
        if let encoded = try? JSONEncoder().encode(modes) {
            userDefaults.set(encoded, forKey: "modes")
        }
        if let preferredInputDeviceID {
            userDefaults.set(preferredInputDeviceID, forKey: "preferredInputDeviceID")
        } else {
            userDefaults.removeObject(forKey: "preferredInputDeviceID")
        }
        Logger.settings.info("Settings saved")
    }
}
