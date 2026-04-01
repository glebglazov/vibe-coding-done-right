import Foundation

/// Encapsulates the "copied!" feedback pattern: sets a boolean true,
/// sleeps for a duration, then resets it to false.
///
/// The returned Task is fire-and-forget by design: the only effect is
/// toggling a view-local boolean back to false after a delay. If the view
/// disappears before the timer fires, the write is harmless (no side effects
/// beyond setting a @State bool). Callers may store and cancel the task if
/// they need deterministic cleanup, but it is not required.
enum CopiedFeedback {
    // MARK: - Constants

    static let duration: Duration = .seconds(1.5)

    /// Triggers copied feedback: calls the setter with `true`, waits, then resets to `false`.
    @discardableResult
    @MainActor
    static func trigger(_ setter: @escaping (Bool) -> Void) -> Task<Void, Never> {
        setter(true)
        return Task {
            try? await Task.sleep(for: duration)
            setter(false)
        }
    }
}
