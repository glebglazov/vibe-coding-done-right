import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("HoldToDiscardController")
struct HoldToDiscardControllerTests {

    @Test("release before hold threshold performs Stop")
    func releaseBeforeThresholdStops() async {
        var stopCount = 0
        var discardCount = 0

        let controller = HoldToDiscardController(
            onStop: { stopCount += 1 },
            onDiscard: { discardCount += 1 }
        )

        controller.touchDown()
        try? await Task.sleep(for: .milliseconds(500))
        controller.touchUp()

        #expect(stopCount == 1)
        #expect(discardCount == 0)
    }

    @Test("hold through threshold fires Discard without waiting for release")
    func holdThroughThresholdDiscards() async {
        var stopCount = 0
        var discardCount = 0
        var hapticCount = 0

        let controller = HoldToDiscardController(
            onStop: { stopCount += 1 },
            onDiscard: { discardCount += 1 },
            onDiscardHaptic: { hapticCount += 1 }
        )

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.holdDuration + 0.05))

        #expect(discardCount == 1)
        #expect(hapticCount == 1)
        #expect(stopCount == 0)

        controller.touchUp()
        #expect(stopCount == 0)
        #expect(discardCount == 1)
    }
}
