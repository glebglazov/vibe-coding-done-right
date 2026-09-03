import Foundation
import Testing
@testable import vcdr_mac

/// Drives the narrator the way the phase poller does — repeated readings of a
/// phase as the clock moves — and pins what the readiness surfaces then show.
@Suite("Model preparation narration")
struct ModelPreparationNarratorTests {
    private static let threshold = ModelPreparationPhase.heartbeatRevealThreshold

    @Test("a long phase gains the heartbeat, a short one does not")
    func heartbeatFollowsTimeInPhase() {
        let start = ContinuousClock.now
        var narrator = ModelPreparationNarrator(now: start)

        #expect(
            narrator.readiness(for: .loadingModel, at: start)
                == .preparing(label: "Loading model")
        )
        #expect(
            narrator.readiness(for: .loadingModel, at: start.advanced(by: .seconds(Self.threshold)))
                == .preparing(label: "Loading model · \(Self.threshold)s")
        )
    }

    @Test("the heartbeat counts the current phase, not the whole launch")
    func phaseChangeRestartsTheHeartbeat() {
        let start = ContinuousClock.now
        var narrator = ModelPreparationNarrator(now: start)

        _ = narrator.readiness(for: .downloadingModel, at: start)
        let handover = start.advanced(by: .seconds(30))
        #expect(
            narrator.readiness(for: .loadingModel, at: handover)
                == .preparing(label: "Loading model")
        )
        #expect(
            narrator.readiness(for: .loadingModel, at: handover.advanced(by: .seconds(Self.threshold)))
                == .preparing(label: "Loading model · \(Self.threshold)s")
        )
    }

    @Test("a launch that never enters the downloading phase never says downloading")
    func cachedLaunchNeverClaimsToDownload() {
        let start = ContinuousClock.now
        var narrator = ModelPreparationNarrator(now: start)

        let cachedLaunch: [ModelReadiness] = [
            narrator.readiness(for: .preparing, at: start),
            narrator.readiness(for: .loadingModel, at: start.advanced(by: .milliseconds(200))),
            narrator.readiness(for: .ready, at: start.advanced(by: .seconds(4)))
        ]

        #expect(cachedLaunch.last == .ready)
        for readiness in cachedLaunch {
            guard case .preparing(let label) = readiness else { continue }
            #expect(!label.contains("Downloading"))
        }
    }
}
