import UIKit

/// Retained, pre-warmed impact generators for the app.
///
/// Constructing a generator at fire time makes the first impact pay the cost of
/// waking the haptic daemon, which under cold-launch contention has been
/// measured blocking the main thread for seconds. The Discard Warning's haptic
/// ladder fires mid-gesture, so it cannot afford that: the generators are built
/// once, `prepare()`d before the gesture can start, and re-prepared after each
/// impact to keep the connection warm.
@MainActor
enum AppHaptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)

    /// Warms the haptic engine. Cheap once warm; call it when a surface that
    /// can start a hold appears, not when the hold begins.
    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
    }

    static func light() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    static func medium() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }
}
