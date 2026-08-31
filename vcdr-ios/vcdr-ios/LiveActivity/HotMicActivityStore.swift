import ActivityKit
import Foundation
import OSLog

/// The ActivityKit surface `HotMicActivityController` drives, expressed in
/// activity identifiers instead of `Activity` handles.
///
/// ActivityKit only vends a real `Activity` from a running process talking to
/// the system daemon, so without this seam the controller's contract — one card
/// per session, refreshed while the app beats, none left behind — could only be
/// checked on a device. `ActivityKitPresenceStore` is the production adapter.
@MainActor
protocol HotMicActivityStore {
    /// Whether the user still has Live Activities enabled for this app.
    var areActivitiesEnabled: Bool { get }
    /// Every Hot Mic Live Activity the system currently holds for this app —
    /// including cards this process never requested, left by a previous run.
    var liveActivityIDs: [String] { get }
    /// Requests a new activity whose readiness claim expires at `staleDate`,
    /// answering its identifier, or `nil` when the system refuses.
    func request(staleDate: Date) async -> String?
    /// Pushes an on-screen card's readiness claim out to a new `staleDate`.
    func update(id: String, staleDate: Date) async
    /// Removes a card now. The card is never ended with a scheduled dismissal:
    /// ending freezes an activity, and a frozen card cannot be corrected when
    /// readiness dies early (ADR-0006).
    func end(id: String) async
}

/// Production adapter over ActivityKit.
@MainActor
struct ActivityKitPresenceStore: HotMicActivityStore {
    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var liveActivityIDs: [String] { Activity<HotMicActivityAttributes>.activities.map(\.id) }

    func request(staleDate: Date) async -> String? {
        do {
            let attrs = HotMicActivityAttributes()
            // `Activity.request` is synchronous and talks to the ActivityKit
            // daemon; under cold-launch contention (parallel ANE model compile)
            // that IPC has been observed to block for ~8s. Running it directly
            // would pin this `@MainActor` call for that whole time, stalling the
            // recording-start path and freezing SwiftUI updates. Offload to a GCD
            // thread via the blocking-task bridge — same pattern as model load —
            // so the main actor stays free. `Activity` and its attributes/content
            // are Sendable, so the value crosses back cleanly.
            let activity = try await withThrowingBlockingTask(qos: .userInitiated) {
                try Activity.request(attributes: attrs, content: Self.content(staleDate: staleDate))
            }
            return activity.id
        } catch {
            Logger.app.error("Live Activity request failed: \(error)")
            return nil
        }
    }

    func update(id: String, staleDate: Date) async {
        await activity(id)?.update(Self.content(staleDate: staleDate))
    }

    func end(id: String) async {
        await activity(id)?.end(nil, dismissalPolicy: .immediate)
    }

    private func activity(_ id: String) -> Activity<HotMicActivityAttributes>? {
        Activity<HotMicActivityAttributes>.activities.first { $0.id == id }
    }

    /// `ContentState` is empty because the card makes exactly one claim, and the
    /// claim is the `staleDate` on the content around it: readiness holds until
    /// that instant. Past it, iOS renders the not-ready face on its own — the
    /// only correction that still happens once this process is gone.
    nonisolated private static func content(staleDate: Date) -> ActivityContent<HotMicActivityAttributes.ContentState> {
        ActivityContent(state: HotMicActivityAttributes.ContentState(), staleDate: staleDate)
    }
}
