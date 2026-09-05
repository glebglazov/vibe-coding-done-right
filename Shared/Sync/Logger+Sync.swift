import OSLog

/// Sync subsystem logger — the reconciler and the migration that fills a
/// container for the first time, both of which carry either dataset and so
/// belong to neither one's category.
extension Logger {
    static let sync = AppLog(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr.sync",
        category: "sync"
    )
}
