import UIKit

/// Retained, pre-warmed impact generators for the app.
///
/// Constructing a generator at fire time makes the first impact pay the cost of
/// waking the haptic daemon, which under cold-launch contention has been
/// measured blocking the main thread for seconds. The generators are built
/// once and re-prepared after each impact to keep the connection warm.
@MainActor
enum AppHaptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)

    static func light() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    static func medium() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }
}
