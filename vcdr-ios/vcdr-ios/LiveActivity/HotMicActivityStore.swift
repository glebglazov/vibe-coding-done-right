import ActivityKit
import Foundation
import OSLog

/// The ActivityKit surface `HotMicActivityController` drives, expressed in
/// activity identifiers instead of `Activity` handles.
///
/// ActivityKit only vends a real `Activity` from a running process talking to
/// the system daemon, so without this seam the controller's serialization
/// contract — one card per session, none left behind — could only be checked on
/// a device. `ActivityKitPresenceStore` is the production adapter.
@MainActor
protocol HotMicActivityStore {
    /// Whether the user still has Live Activities enabled for this app.
    var areActivitiesEnabled: Bool { get }
    /// Every Hot Mic Live Activity the system currently holds for this app —
    /// including cards this process never requested, left by a previous run.
    var liveActivityIDs: [String] { get }
    /// Requests a new activity, answering its identifier, or `nil` when the
    /// system refuses.
    func request() async -> String?
    /// Refreshes the content of a card that is already on screen.
    func update(id: String) async
    /// Ends an activity. A `nil` deadline removes the card immediately;
    /// otherwise iOS keeps rendering it and removes it autonomously at that
    /// instant, which is how a finite Presence Deadline survives app suspension.
    func end(id: String, dismissingAt deadline: Date?) async
}

/// Production adapter over ActivityKit.
@MainActor
struct ActivityKitPresenceStore: HotMicActivityStore {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var liveActivityIDs: [String] { Activity<HotMicActivityAttributes>.activities.map(\.id) }

    func request() async -> String? {
        do {
            let attrs = HotMicActivityAttributes()
            let contentState = makeContentState()
            // `Activity.request` is synchronous and talks to the ActivityKit
            // daemon; under cold-launch contention (parallel ANE model compile)
            // that IPC has been observed to block for ~8s. Running it directly
            // would pin this `@MainActor` call for that whole time, stalling the
            // recording-start path and freezing SwiftUI updates. Offload to a GCD
            // thread via the blocking-task bridge — same pattern as model load —
            // so the main actor stays free. `Activity` and its attributes/content
            // are Sendable, so the value crosses back cleanly.
            let activity = try await withThrowingBlockingTask(qos: .userInitiated) {
                try Activity.request(attributes: attrs, contentState: contentState)
            }
            return activity.id
        } catch {
            Logger.app.error("Live Activity request failed: \(error)")
            return nil
        }
    }

    func update(id: String) async {
        await activity(id)?.update(using: makeContentState())
    }

    func end(id: String, dismissingAt deadline: Date?) async {
        guard let activity = activity(id) else { return }
        if let deadline {
            await activity.end(using: makeContentState(), dismissalPolicy: .after(deadline))
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func activity(_ id: String) -> Activity<HotMicActivityAttributes>? {
        Activity<HotMicActivityAttributes>.activities.first { $0.id == id }
    }

    /// Content is intentionally deadline-free. Finite Mic Presence windows are
    /// represented by ending the activity with `.after(deadline)`, letting iOS
    /// remove it autonomously at the Presence Deadline while it continues to
    /// render the same readiness signal.
    private func makeContentState() -> HotMicActivityAttributes.ContentState {
        HotMicActivityAttributes.ContentState()
    }
}
