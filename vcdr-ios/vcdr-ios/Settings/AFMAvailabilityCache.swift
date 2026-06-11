import Foundation
import FoundationModels
import OSLog

/// Caches `SystemLanguageModel.default.isAvailable`. The synchronous accessor
/// can block the main thread for tens of seconds on first launch after install
/// while iOS resolves Apple Intelligence capability and asset state. UI reads
/// the cached flag instead and re-renders via observation when the off-main
/// probe lands.
@MainActor
@Observable
final class AFMAvailabilityCache {
    static let shared = AFMAvailabilityCache()

    /// Last known availability. Starts `false` and flips to the real value
    /// once `refresh()` completes.
    private(set) var isAvailable = false

    private var probe: Task<Bool, Never>?

    private init() {}

    /// Probes availability off the main actor and updates the cached value.
    /// Concurrent callers share the in-flight probe.
    @discardableResult
    func refresh() async -> Bool {
        if let probe { return await probe.value }
        Logger.app.info("[LaunchProbe] AFMAvailabilityCache.refresh entry main=\(Thread.isMainThread)")
        // The availability accessor blocks for tens of seconds on first launch,
        // so it must run on GCD, not the cooperative pool (ADR-0003).
        let task = Task {
            await withBlockingTask(qos: .utility) {
                Logger.app.info("[LaunchProbe] AFMAvailabilityCache probe body start main=\(Thread.isMainThread)")
                let result = SystemLanguageModel.default.isAvailable
                Logger.app.info("[LaunchProbe] AFMAvailabilityCache probe body end main=\(Thread.isMainThread) available=\(result)")
                return result
            }
        }
        probe = task
        let result = await task.value
        probe = nil
        isAvailable = result
        Logger.app.info("[LaunchProbe] AFMAvailabilityCache.refresh exit main=\(Thread.isMainThread)")
        return result
    }
}
