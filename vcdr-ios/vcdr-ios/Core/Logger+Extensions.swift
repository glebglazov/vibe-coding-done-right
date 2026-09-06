import OSLog

nonisolated extension Logger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "vcdr-ios"

    static let app = AppLog(subsystem: subsystem, category: "app")
    static let recording = AppLog(subsystem: subsystem, category: "recording")
    static let ai = AppLog(subsystem: subsystem, category: "ai")
}
