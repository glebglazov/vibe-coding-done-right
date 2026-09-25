import OSLog
import UIKit

/// Keeps the process running while `work` runs, even when VCDR is not on
/// screen. Every Finalizing runs inside one, so a stop from the keyboard, the
/// card or a Shortcut still reaches its Completion Delivery.
@MainActor
protocol BackgroundTaskRunner {
    func run<T>(named name: String, _ work: () async -> T) async -> T
}

/// Wraps `work` in `UIApplication.beginBackgroundTask(withName:)` and ends the
/// task once, when `work` returns or when the system expires it. After an
/// expiry the process may suspend, and `work` goes on when it next runs.
@MainActor
struct UIKitBackgroundTaskRunner: BackgroundTaskRunner {
    func run<T>(named name: String, _ work: () async -> T) async -> T {
        let task = BackgroundTask(named: name)
        let result = await work()
        task.end()
        return result
    }
}

@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Logger.recording.warning("Background task \(name) expired before its work finished")
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
