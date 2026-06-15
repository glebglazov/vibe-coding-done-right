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
    private var scheduledDismissalDeadline: Date?

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

        guard let deadline else {
            await ensureLiveActivity()
            return
        }

        await scheduleDismissal(at: deadline)
    }

    func stop() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        scheduledDismissalDeadline = nil
        Logger.app.info("Hot mic Live Activity ended")
    }

    private func ensureLiveActivity() async {
        if scheduledDismissalDeadline != nil {
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            scheduledDismissalDeadline = nil
        } else if let activity {
            await activity.update(using: makeContentState())
            return
        }

        activity = await requestActivity()
    }

    private func scheduleDismissal(at deadline: Date) async {
        if let scheduledDismissalDeadline {
            guard deadline < scheduledDismissalDeadline else { return }
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            self.scheduledDismissalDeadline = nil
        }

        if activity == nil {
            activity = await requestActivity()
        }

        guard let activity else { return }
        await activity.end(using: makeContentState(), dismissalPolicy: .after(deadline))
        scheduledDismissalDeadline = deadline
        Logger.app.info("Hot mic Live Activity scheduled to dismiss at \(deadline)")
    }

    private func requestActivity() async -> Activity<HotMicActivityAttributes>? {
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
            Logger.app.info("Hot mic Live Activity started")
            return activity
        } catch {
            Logger.app.error("Live Activity request failed: \(error)")
            return nil
        }
    }

    /// Content is intentionally deadline-free. Finite Mic Presence windows are
    /// represented by ending the activity with `.after(deadline)`, letting iOS
    /// remove it autonomously at the Presence Deadline while it continues to
    /// render the same readiness signal.
    private func makeContentState() -> HotMicActivityAttributes.ContentState {
        HotMicActivityAttributes.ContentState()
    }
}
