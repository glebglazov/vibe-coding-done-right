import Observation

/// Tells VCDR which app opened it through the keyboard. `Observable` so a
/// Host Return attempt wakes on a new sighting instead of polling.
@MainActor
protocol HostAppSource: AnyObject, Observable {
    var state: HostAppSourceState { get }
    /// Begins observing. Call once, before the first scene connects, so a
    /// cold launch from the keyboard sees the host.
    func start()
}
