import OSLog

/// Logging facade. Every call fans out to two sinks:
///   1. Apple's unified log (`os.Logger`) — visible in Console.app / Xcode.
///   2. `LogBuffer` — a best-effort persistent, size-capped file in the App
///      Group container, read back by the in-app debug log viewer. Its storage
///      setup and writes stay off the calling thread.
///
/// Call sites are unchanged from raw `os.Logger`: `Logger.recording.info("…")`.
/// The named channels live on `extension Logger` purely as a namespace, so the
/// `Logger.<channel>.<level>(…)` spelling keeps working while the underlying
/// type is now `AppLog`.
///
/// Messages are plain `String`. The OS mirror is emitted as `.public` so Console
/// shows the same text the in-app viewer captures — no granular privacy
/// redaction. Don't log secrets through this facade.
/// `nonisolated`, not MainActor-inferred: the wire write, the log buffer's own
/// queue and every background pipeline log from outside the main actor. Both
/// sinks are already thread-safe (`os.Logger` is Sendable, `LogBuffer` confines
/// its file state to a serial queue), so isolation would buy nothing and cost
/// every off-main call site an await.
nonisolated struct AppLog: Sendable {
    private let os: Logger
    private let category: String

    init(subsystem: String, category: String) {
        self.os = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        os.debug("\(message, privacy: .public)")
        buffer("D", message)
    }

    func info(_ message: String) {
        os.info("\(message, privacy: .public)")
        buffer("I", message)
    }

    func notice(_ message: String) {
        os.notice("\(message, privacy: .public)")
        buffer("N", message)
    }

    func warning(_ message: String) {
        os.warning("\(message, privacy: .public)")
        buffer("W", message)
    }

    func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        buffer("E", message)
    }

    func fault(_ message: String) {
        os.fault("\(message, privacy: .public)")
        buffer("F", message)
    }

    private func buffer(_ level: String, _ message: String) {
        LogBuffer.shared.append(category: category, level: level, message: message)
    }
}
