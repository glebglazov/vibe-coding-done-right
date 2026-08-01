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

    @Test("nothing shows during the Discard Dwell")
    func dwellShowsNothing() async {
        let controller = HoldToDiscardController(onStop: {}, onDiscard: {})

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.dwellDuration - 0.15))

        #expect(controller.isHolding)
        #expect(controller.isWarning == false)
        #expect(controller.warningProgress == 0)

        controller.touchUp()
    }

    @Test("warning appears after the dwell and ramps across the warning window")
    func warningRampsAfterDwell() async {
        var rampSamples: [CGFloat] = []

        let controller = HoldToDiscardController(
            onStop: {},
            onDiscard: {},
            onWarningRamp: { rampSamples.append($0) }
        )

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.dwellDuration + 0.1))

        #expect(controller.isWarning)
        // Just past the dwell the ramp has barely started, measured within the
        // warning window rather than the whole hold.
        #expect(controller.warningProgress > 0)
        #expect(controller.warningProgress < 0.2)

        try? await Task.sleep(for: .seconds(HoldToDiscardController.warningDuration / 2))

        #expect(controller.warningProgress > 0.4)
        #expect(controller.warningProgress < 0.8)
        #expect(rampSamples.isEmpty == false)
        #expect(rampSamples.first ?? 1 < 0.2)

        controller.touchUp()
    }

    @Test("releasing mid-warning stops and reports the abandonment")
    func releaseMidWarningReportsAbandonment() async {
        var stopCount = 0
        var discardCount = 0

        let controller = HoldToDiscardController(
            onStop: { stopCount += 1 },
            onDiscard: { discardCount += 1 }
        )

        controller.touchDown()
        try? await Task.sleep(
            for: .seconds(HoldToDiscardController.dwellDuration + HoldToDiscardController.warningDuration / 2)
        )
        let reached = controller.warningProgress
        controller.touchUp()

        #expect(stopCount == 1)
        #expect(discardCount == 0)
        #expect(controller.isWarning == false)
        #expect(controller.abandonment?.warningProgress == reached)
        #expect(reached > 0)
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
        // Reaching the threshold is not an abandonment.
        #expect(controller.abandonment == nil)
    }

    @Test("discardImmediately fires Discard with no hold in progress")
    func discardImmediatelyWithNoHold() async {
        var stopCount = 0
        var discardCount = 0

        let controller = HoldToDiscardController(
            onStop: { stopCount += 1 },
            onDiscard: { discardCount += 1 }
        )

        controller.discardImmediately()

        #expect(discardCount == 1)
        #expect(stopCount == 0)
    }

    @Test("discardImmediately mid-hold discards once and release afterwards doesn't also Stop")
    func discardImmediatelyMidHoldDoesNotDoubleFire() async {
        var stopCount = 0
        var discardCount = 0

        let controller = HoldToDiscardController(
            onStop: { stopCount += 1 },
            onDiscard: { discardCount += 1 }
        )

        controller.touchDown()
        try? await Task.sleep(
            for: .seconds(HoldToDiscardController.dwellDuration + HoldToDiscardController.warningDuration / 2)
        )
        controller.discardImmediately()

        #expect(discardCount == 1)
        #expect(stopCount == 0)

        // The pending threshold timer must be cancelled — waiting past where it
        // would have fired must not produce a second Discard.
        try? await Task.sleep(for: .seconds(HoldToDiscardController.warningDuration / 2 + 0.1))
        #expect(discardCount == 1)

        // A release that follows must not also perform Stop.
        controller.touchUp()
        #expect(stopCount == 0)
        #expect(discardCount == 1)
    }

    @Test("steppedForReduceMotion quantizes into discrete jumps")
    func steppedForReduceMotionQuantizes() {
        let steps = HoldToDiscardController.reduceMotionSteps

        #expect(CGFloat(0).steppedForReduceMotion() == 0)
        #expect(CGFloat(1).steppedForReduceMotion() == 1)

        // A value strictly between two step boundaries snaps down to the
        // lower boundary rather than reading as continuous motion.
        let midStep = (CGFloat(1) / CGFloat(steps)) / 2
        #expect(midStep.steppedForReduceMotion() == 0)

        let justPastFirstBoundary = CGFloat(1) / CGFloat(steps) + 0.001
        #expect(justPastFirstBoundary.steppedForReduceMotion() == CGFloat(1) / CGFloat(steps))
    }
}
