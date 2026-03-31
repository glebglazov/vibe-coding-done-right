import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "glebglazov.vcdr"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let actions = Logger(subsystem: subsystem, category: "actions")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let consistency = Logger(subsystem: subsystem, category: "consistency")
    static let voiceLock = Logger(subsystem: subsystem, category: "voiceLock")
}
