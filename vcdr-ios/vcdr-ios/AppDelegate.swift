import UIKit

/// Captures the launch URL before SwiftUI has a chance to render the first
/// frame. Without this, cold-launch-via-keyboard races with `.task` /
/// `.onOpenURL` delivery and the user sees PREPARING for a beat before the
/// view switches to LISTENING. `didFinishLaunchingWithOptions` runs during
/// `UIApplicationMain`, strictly before the SwiftUI scene is constructed,
/// so the @State coordinator initializer can read the flag below and
/// pre-flip its state to `.recording`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL,
           url.scheme == "vcdr-ios", url.host == "record" {
            PendingLaunchIntent.recordRequested = true
        }
        return true
    }
}

/// One-shot flag consumed by the scene's @State coordinator initializer.
/// Never read by UI code directly — the coordinator flips state and clears
/// the flag so scene re-renders don't re-trigger the deep-link entry.
enum PendingLaunchIntent {
    static var recordRequested = false
}
