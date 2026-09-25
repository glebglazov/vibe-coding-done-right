import Foundation
@testable import vcdr_ios

@MainActor
final class SpyMicPresenceCard: MicPresence, RecordingRunPresence {
    var areActivitiesEnabled = true
    var showsCard = true
    /// Runs inside `isShowingCard()`, where ActivityKit would suspend the
    /// caller, so a test can change the run behind the check.
    var whileCheckingCard: (@MainActor () async -> Void)?
    var onRunChanged: (@MainActor (MicPresenceRun?) -> Void)?
    var onSettled: (@MainActor () -> Void)?
    private(set) var runs: [MicPresenceRun?] = []
    private(set) var reachability: [Bool] = []
    private(set) var scenes: [Bool] = []

    func reachabilityChanged(_ reachable: Bool) {
        reachability.append(reachable)
    }

    func runChanged(_ run: MicPresenceRun?) {
        runs.append(run)
        onRunChanged?(run)
    }

    func sceneChanged(foreground: Bool) {
        scenes.append(foreground)
    }

    func settled() async {
        onSettled?()
    }

    func isShowingCard() async -> Bool {
        await whileCheckingCard?()
        return showsCard
    }
}
