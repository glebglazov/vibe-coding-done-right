import Foundation
import Testing
@testable import vcdr_mac

/// Pins the line a held-up run shows: the phase the menu bar would name, the
/// Preparation Heartbeat once the wait is long enough to have one, and the
/// assurance that is the whole reason the line exists.
@Suite("Model preparation notice")
struct ModelPreparationNoticeTests {
    private static let threshold = ModelPreparationPhase.heartbeatRevealThreshold

    @Test("the wait names the phase, counts its seconds, and says the recording is safe")
    func waitLineCarriesPhaseHeartbeatAndAssurance() {
        let start = ContinuousClock.now
        var notice = ModelPreparationNotice(now: start)

        #expect(
            notice.line(for: .downloadingModel, at: start)
                == "Downloading model — your recording is safe"
        )
        #expect(
            notice.line(for: .downloadingModel, at: start.advanced(by: .seconds(Self.threshold)))
                == "Downloading model · \(Self.threshold)s — your recording is safe"
        )
    }

    @Test("a ready model leaves nothing to say")
    func readyModelHasNoLine() {
        var notice = ModelPreparationNotice()

        #expect(notice.line(for: .ready) == nil)
    }
}
