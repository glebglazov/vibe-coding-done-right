import OSLog

extension Logger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "glebglazov.vcdr-mac"

    static let app = AppLog(subsystem: subsystem, category: "app")
    static let recording = AppLog(subsystem: subsystem, category: "recording")
    static let hotkeys = AppLog(subsystem: subsystem, category: "hotkeys")
    static let actions = AppLog(subsystem: subsystem, category: "actions")
    static let settings = AppLog(subsystem: subsystem, category: "settings")
    static let audio = AppLog(subsystem: subsystem, category: "audio")
    static let ui = AppLog(subsystem: subsystem, category: "ui")
    static let consistency = AppLog(subsystem: subsystem, category: "consistency")
    static let styles = AppLog(subsystem: subsystem, category: "styles")
    static let textTransform = AppLog(subsystem: subsystem, category: "textTransform")
}
