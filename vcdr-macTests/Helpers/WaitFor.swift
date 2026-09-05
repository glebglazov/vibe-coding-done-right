import Foundation

/// Polls `condition` until it holds or the timeout expires.
///
/// Settings-driven re-arming lands through `withObservationTracking`, which hops to
/// the main actor before it applies — so a test that writes a shortcut and asserts
/// the armed set has to wait for it rather than read straight after the write.
@MainActor
func waitFor(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    _ condition: @escaping () -> Bool
) async -> Bool {
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        if condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return false
}
