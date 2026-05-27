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

    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logger.app.info("Live Activities disabled in Settings")
            return
        }
        let content = makeContent()
        if let activity {
            await activity.update(content)
            return
        }
        do {
            let attrs = HotMicActivityAttributes()
            activity = try Activity.request(attributes: attrs, content: content)
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

    private func makeContent() -> ActivityContent<HotMicActivityAttributes.ContentState> {
        ActivityContent(
            state: HotMicActivityAttributes.ContentState(),
            staleDate: nil
        )
    }
}
