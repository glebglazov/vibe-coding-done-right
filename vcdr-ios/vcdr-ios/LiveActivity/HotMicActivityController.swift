import Foundation
import OSLog

/// Surfaces a Live Activity while the mic engine is running. Used purely as a
/// visible "this is VCDR using the mic" signal on the lock screen and Dynamic
/// Island — the system orange mic dot cannot be suppressed, this gives it
/// identity instead. Lifecycle is tied to the hot audio engine, not to the
/// recording flag.
///
/// Every operation is serialized: show, hide and refresh each run to completion
/// before the next starts. Callers fan in from several places at once (recording
/// start, idle re-arm, policy change) and the ActivityKit request suspends for
/// as long as seconds, so without ordering two overlapping shows each saw an
/// empty slot and requested their own card — leaving an orphan that outlived
/// teardown and kept advertising readiness with the engine down.
@MainActor
final class HotMicActivityController {
    private let store: any HotMicActivityStore
    /// The card this controller believes it owns. The system may hold others.
    private var activityID: String?
    private var scheduledDismissalDeadline: Date?
    /// Tail of the serialized operation chain — every new operation awaits it
    /// before touching state, and becomes the tail in turn.
    private var lastOperation: Task<Void, Never>?

    /// The store is optional rather than a defaulted argument because
    /// default-argument expressions evaluate in a nonisolated context and so
    /// cannot construct this `@MainActor` value.
    init(store: (any HotMicActivityStore)? = nil) {
        self.store = store ?? ActivityKitPresenceStore()
        // End any activity that survived a previous app kill. If the engine
        // comes back up via `start()`, a fresh one is requested — and because
        // the sweep is the first link in the chain, that request cannot be
        // swept away by it.
        enqueue(.sweepStrays)
    }

    func start(deadline: Date?) async {
        guard store.areActivitiesEnabled else {
            Logger.app.info("Live Activities disabled in Settings")
            return
        }
        await enqueue(.show(deadline: deadline)).value
    }

    func stop() async {
        await enqueue(.hide).value
    }

    // MARK: - Serialization

    private enum PresenceOperation {
        case show(deadline: Date?)
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
        case .show(let deadline):
            if let deadline {
                await showEnding(at: deadline)
            } else {
                await showIndefinitely()
            }
        case .hide:
            await hide()
        case .sweepStrays:
            await endEveryActivity()
        }
    }

    // MARK: - Operations

    private func showIndefinitely() async {
        if scheduledDismissalDeadline != nil {
            // iOS owns the pending dismissal and offers no way to withdraw it,
            // so an open-ended presence has to trade the card for a fresh one.
            await endCurrentActivity()
        } else if let activityID {
            await store.update(id: activityID)
            return
        }

        await requestActivity()
    }

    private func showEnding(at deadline: Date) async {
        if let scheduledDismissalDeadline {
            guard deadline < scheduledDismissalDeadline else { return }
            await endCurrentActivity()
        }

        if activityID == nil {
            await requestActivity()
        }

        guard let activityID else { return }
        await store.end(id: activityID, dismissingAt: deadline)
        scheduledDismissalDeadline = deadline
        Logger.app.info("Hot mic Live Activity scheduled to dismiss at \(deadline)")
    }

    private func hide() async {
        let endedAnything = await endEveryActivity()
        guard endedAnything else { return }
        Logger.app.info("Hot mic Live Activity ended")
    }

    private func requestActivity() async {
        activityID = await store.request()
        guard activityID != nil else { return }
        Logger.app.info("Hot mic Live Activity started")
    }

    private func endCurrentActivity() async {
        if let activityID {
            await store.end(id: activityID, dismissingAt: nil)
        }
        activityID = nil
        scheduledDismissalDeadline = nil
    }

    /// Ends every card the system holds for this app, not only the one this
    /// controller remembers. A process killed mid-session leaves behind a card
    /// nothing else clears; it keeps saying "ready" with the mic engine down, so
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
            await store.end(id: id, dismissingAt: nil)
        }
        activityID = nil
        scheduledDismissalDeadline = nil
        return !ids.isEmpty
    }
}
