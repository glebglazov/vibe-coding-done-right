import Foundation
import OSLog

/// Surfaces a Live Activity while the mic engine is running. Used purely as a
/// visible "this is VCDR using the mic" signal on the lock screen and Dynamic
/// Island — the system orange mic dot cannot be suppressed, this gives it
/// identity instead. Lifecycle is tied to the hot audio engine, not to the
/// recording flag.
///
/// The card is kept *live* and re-stamped on every Heartbeat tick with a stale
/// horizon one freshness window wide (ADR-0006). It is never ended with a
/// scheduled dismissal: ending freezes a card on screen, and a frozen card goes
/// on claiming readiness after a force quit, a jetsam or a teardown while
/// suspended. Letting the horizon lapse instead hands the correction to iOS,
/// the one thing that still happens with no app code running.
///
/// Every operation is serialized: show, refresh and hide each run to completion
/// before the next starts. Callers fan in from several places at once (recording
/// start, idle re-arm, policy change, heartbeat) and the ActivityKit request
/// suspends for as long as seconds, so without ordering two overlapping shows
/// each saw an empty slot and requested their own card — leaving an orphan that
/// outlived teardown and kept advertising readiness with the engine down.
@MainActor
final class HotMicActivityController {
    private let store: any HotMicActivityStore
    private let now: () -> Date
    /// The card this controller believes it owns. The system may hold others.
    private var activityID: String?
    /// Tail of the serialized operation chain — every new operation awaits it
    /// before touching state, and becomes the tail in turn.
    private var lastOperation: Task<Void, Never>?

    /// How far ahead of the moment of writing a card's readiness claim reaches.
    /// It is the Heartbeat freshness window itself, not a copy of it: the card
    /// and the keyboard's record control must change their minds about In-Place
    /// Reachability at the same instant.
    private static var staleHorizon: TimeInterval { KeyboardChannel.heartbeatFreshnessWindow }

    /// The store is optional rather than a defaulted argument because
    /// default-argument expressions evaluate in a nonisolated context and so
    /// cannot construct this `@MainActor` value.
    init(store: (any HotMicActivityStore)? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store ?? ActivityKitPresenceStore()
        self.now = now
        // End any activity that survived a previous app kill. If the engine
        // comes back up via `start()`, a fresh one is requested — and because
        // the sweep is the first link in the chain, that request cannot be
        // swept away by it.
        enqueue(.sweepStrays)
    }

    func start() async {
        guard store.areActivitiesEnabled else {
            Logger.app.info("Live Activities disabled in Settings")
            return
        }
        await enqueue(.show).value
    }

    func refresh() async {
        await enqueue(.refreshHorizon).value
    }

    func stop() async {
        await enqueue(.hide).value
    }

    // MARK: - Serialization

    private enum PresenceOperation {
        case show
        case refreshHorizon
        case hide
        case sweepStrays
    }

    /// Appends an operation to the chain. Reading and replacing `lastOperation`
    /// happens with no suspension in between, so a caller arriving during
    /// another operation's `await` still lands behind it rather than beside it.
    @discardableResult
    private func enqueue(_ operation: PresenceOperation) -> Task<Void, Never> {
        let predecessor = lastOperation
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            await self?.perform(operation)
        }
        lastOperation = task
        return task
    }

    private func perform(_ operation: PresenceOperation) async {
        switch operation {
        case .show:
            await show()
        case .refreshHorizon:
            await refreshHorizon()
        case .hide:
            await hide()
        case .sweepStrays:
            await endEveryActivity()
        }
    }

    // MARK: - Operations

    private func show() async {
        if let activityID {
            await store.update(id: activityID, staleDate: staleDate())
            return
        }
        activityID = await store.request(staleDate: staleDate())
        guard activityID != nil else { return }
        Logger.app.info("Hot mic Live Activity started")
    }

    /// Carries an on-screen card's claim one window further. Requests nothing
    /// when there is no card: a beat renews readiness that presence already
    /// asserts, it never asserts readiness of its own.
    private func refreshHorizon() async {
        guard let activityID else { return }
        await store.update(id: activityID, staleDate: staleDate())
    }

    private func hide() async {
        let endedAnything = await endEveryActivity()
        guard endedAnything else { return }
        Logger.app.info("Hot mic Live Activity ended")
    }

    private func staleDate() -> Date {
        now().addingTimeInterval(Self.staleHorizon)
    }

    /// Ends every card the system holds for this app, not only the one this
    /// controller remembers. A process killed mid-session leaves behind a card
    /// nothing else clears; it goes stale on its own but stays on screen, so
    /// withdrawing presence has to reconcile against the system's list.
    @discardableResult
    private func endEveryActivity() async -> Bool {
        var ids = store.liveActivityIDs
        // The daemon can lag a just-granted request, so the card we hold is not
        // always in its list yet.
        if let activityID, !ids.contains(activityID) {
            ids.append(activityID)
        }
        for id in ids {
            await store.end(id: id)
        }
        activityID = nil
        return !ids.isEmpty
    }
}
