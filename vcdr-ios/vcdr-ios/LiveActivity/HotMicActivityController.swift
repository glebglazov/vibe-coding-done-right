import Foundation
import OSLog

/// Holds the Mic Presence card in ActivityKit: one card at a time, on the face
/// `MicPresenceCard` decides. The system orange mic dot cannot be suppressed,
/// and this card gives it identity.
///
/// A live card is re-stamped on every render with a stale horizon one Heartbeat
/// freshness window wide (ADR-0006). Only an outcome face is ended with a
/// scheduled dismissal: ending freezes a card on screen, which is honest for
/// "Copied" and dishonest for a readiness claim.
///
/// Every render is serialized and runs to completion before the next starts.
/// The ActivityKit request suspends for as long as seconds, so without
/// ordering two overlapping renders each saw an empty slot and requested their
/// own card — leaving an orphan that outlived teardown and kept advertising
/// readiness with the engine down.
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
        // End any activity that survived a previous app kill. The sweep is the
        // first link in the chain, so no render's request can be swept away
        // by it.
        enqueue(.sweepStrays)
    }

    var areActivitiesEnabled: Bool { store.areActivitiesEnabled }

    /// True while this controller holds a card it can still update.
    var holdsLiveCard: Bool { activityID != nil }

    /// Enqueues a reconcile toward `decision` and returns at once. Renders run
    /// in order, so the last one wins.
    @discardableResult
    func render(_ decision: MicPresenceCardDecision) -> Task<Void, Never> {
        enqueue(.render(decision))
    }

    /// Waits for every render enqueued so far.
    func settled() async {
        await lastOperation?.value
    }

    // MARK: - Serialization

    private enum PresenceOperation {
        case render(MicPresenceCardDecision)
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
        case .render(.hidden):
            await hide()
        case .render(.live(let state)):
            await show(state)
        case .render(.concluding(let state, let dismissAt)):
            await conclude(state, dismissAt: dismissAt)
        case .sweepStrays:
            await endEveryActivity()
        }
    }

    // MARK: - Operations

    /// Renews the card this controller holds. With none, it ends any card
    /// frozen on an outcome before it requests a new one.
    private func show(_ state: MicPresenceCardState) async {
        if let activityID {
            await store.update(id: activityID, state: state, staleDate: staleDate())
            return
        }
        guard store.areActivitiesEnabled else {
            Logger.app.info("Live Activities disabled in Settings")
            return
        }
        await endEveryActivity()
        activityID = await store.request(state: state, staleDate: staleDate())
        guard activityID != nil else { return }
        Logger.app.info("Mic Presence Live Activity started")
    }

    /// Freezes the held card on its outcome and forgets it, so the next live
    /// render ends it and starts fresh. With no card held there is nothing to
    /// announce the outcome on.
    private func conclude(_ state: MicPresenceCardState, dismissAt: Date) async {
        guard let activityID else { return }
        await store.conclude(id: activityID, state: state, dismissAt: dismissAt)
        self.activityID = nil
    }

    private func hide() async {
        let endedAnything = await endEveryActivity()
        guard endedAnything else { return }
        Logger.app.info("Mic Presence Live Activity ended")
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
