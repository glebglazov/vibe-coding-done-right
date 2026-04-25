import Foundation
import FoundationModels

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
        let task = Task.detached(priority: .utility) {
            SystemLanguageModel.default.isAvailable
        }
        probe = task
        let result = await task.value
        probe = nil
        isAvailable = result
        return result
    }
}
