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

    var actionType: PostTranscriptionActionType {
        didSet { save() }
    }
    var bashCommand: String {
        didSet { save() }
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

        self.actionType = PostTranscriptionActionType(
            rawValue: userDefaults.string(forKey: "actionType") ?? ""
        ) ?? .paste

        self.bashCommand = userDefaults.string(forKey: "bashCommand") ?? "echo {}"
    }

    private func save() {
        userDefaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode")
        userDefaults.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers")
        userDefaults.set(actionType.rawValue, forKey: "actionType")
        userDefaults.set(bashCommand, forKey: "bashCommand")
        Logger.settings.info("Settings saved")
    }
}
