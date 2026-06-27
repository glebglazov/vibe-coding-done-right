import OSLog

/// Substitutions subsystem logger. Lives in `Shared/` so every target that
/// compiles the substitution sources has access — the per-target
/// `Logger+Extensions.swift` files aren't compiled into the keyboard extension.
extension Logger {
    static let substitutions = AppLog(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr.substitutions",
        category: "substitutions"
    )
}
