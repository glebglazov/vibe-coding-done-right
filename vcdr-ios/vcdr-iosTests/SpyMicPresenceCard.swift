import Foundation
@testable import vcdr_ios

@MainActor
final class SpyMicPresenceCard: MicPresence, RecordingRunPresence {
    var areActivitiesEnabled = true
    var showsCard = true
    private(set) var runs: [MicPresenceRun?] = []
    private(set) var reachability: [Bool] = []
    private(set) var scenes: [Bool] = []

    func reachabilityChanged(_ reachable: Bool) {
        reachability.append(reachable)
    }

    func runChanged(_ run: MicPresenceRun?) {
        runs.append(run)
    }

    func sceneChanged(foreground: Bool) {
        scenes.append(foreground)
    }

    func isShowingCard() async -> Bool {
        showsCard
    }
}
