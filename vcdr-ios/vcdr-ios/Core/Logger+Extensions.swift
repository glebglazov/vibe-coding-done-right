import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "vcdr-ios"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let ai = Logger(subsystem: subsystem, category: "ai")
}
