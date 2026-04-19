import OSLog

/// History subsystem logger. Lives in `Shared/` so every target that compiles
/// the history sources (main apps + keyboard extension) has access — the
/// per-target `Logger+Extensions.swift` files aren't compiled into the
/// keyboard extension.
extension Logger {
    static let history = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr.history",
        category: "history"
    )
}
