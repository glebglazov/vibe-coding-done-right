import ActivityKit
import Foundation
import OSLog

/// Surfaces a Live Activity while the mic engine is running. Used purely as a
/// visible "this is VCDR using the mic" signal on the lock screen and Dynamic
/// Island — the system orange mic dot cannot be suppressed, this gives it
/// identity instead. Lifecycle is tied to the hot audio engine, not to the
/// recording flag.
@MainActor
final class HotMicActivityController {
    private var activity: Activity<HotMicActivityAttributes>?

    init() {
        // End any activity that survived a previous app kill. If the engine
        // comes back up via `start()`, a fresh one is requested.
        for existing in Activity<HotMicActivityAttributes>.activities {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(deadline: Date?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logger.app.info("Live Activities disabled in Settings")
            return
        }
        let content = makeContent(deadline: deadline)
        if let activity {
            await activity.update(content)
            return
        }
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
            activity = try await withThrowingBlockingTask(qos: .userInitiated) {
                try Activity.request(attributes: attrs, content: content)
            }
            Logger.app.info("Hot mic Live Activity started")
        } catch {
            Logger.app.error("Live Activity request failed: \(error)")
        }
    }

    func stop() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        Logger.app.info("Hot mic Live Activity ended")
    }

    /// The Presence Deadline maps directly onto the Live Activity stale date:
    /// the system flips the activity to its stale rendering at that wall-clock
    /// instant even while the app is suspended, so "Ready to record" cannot
    /// outlive the finite Hot-Session Timeout. `nil` (e.g. `.always`, or while
    /// recording) leaves the activity with no expiry.
    private func makeContent(deadline: Date?) -> ActivityContent<HotMicActivityAttributes.ContentState> {
        ActivityContent(
            state: HotMicActivityAttributes.ContentState(),
            staleDate: deadline
        )
    }
}
