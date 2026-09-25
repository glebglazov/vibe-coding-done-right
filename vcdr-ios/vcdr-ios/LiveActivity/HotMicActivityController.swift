import Foundation
import OSLog

/// Holds the Mic Presence card in ActivityKit: one card at a time, on the face
/// `MicPresenceCard` decides. The system orange mic dot cannot be suppressed,
/// and this card gives it identity.
///
/// Every render is serialized and runs to completion before the next starts.
/// The ActivityKit request can suspend for seconds.
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
        enqueue(.sweepStrays)
    }

    var areActivitiesEnabled: Bool { store.areActivitiesEnabled }

    var holdsLiveCard: Bool { activityID != nil }

    @discardableResult
    func render(_ decision: MicPresenceCardDecision) -> Task<Void, Never> {
        enqueue(.render(decision))
    }

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
