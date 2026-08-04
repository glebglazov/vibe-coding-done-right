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

    @Test("no warning during the Discard Dwell, only the hint")
    func dwellShowsOnlyTheHint() async {
        let controller = HoldToDiscardController(onStop: {}, onDiscard: {})

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.dwellDuration - 0.15))

        #expect(controller.isHolding)
        // The hint is up well before the dwell ends — the words explain the
        // warning, so they have to precede it.
        #expect(controller.isHinting)
        #expect(controller.isWarning == false)
        #expect(controller.warningProgress == 0)

        controller.touchUp()
        #expect(controller.isHinting == false)
    }

    @Test("a tap shorter than the hint delay never shows the hint")
    func tapShowsNoHint() async {
        let controller = HoldToDiscardController(onStop: {}, onDiscard: {})

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.hintDelay / 2))
        controller.touchUp()

        try? await Task.sleep(for: .seconds(HoldToDiscardController.hintDelay))
        #expect(controller.isHinting == false)
    }

    @Test("reaching the threshold takes the hint down with the warning")
    func discardEndsTheHint() async {
        let controller = HoldToDiscardController(onStop: {}, onDiscard: {})

        controller.touchDown()
        try? await Task.sleep(for: .seconds(HoldToDiscardController.holdDuration + 0.05))

        #expect(controller.isHinting == false)
        #expect(controller.isWarning == false)
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

    /// Task 10's device pass found the tint lingering after release and asked
    /// whether a ramp tick already in flight could still write progress after
    /// `touchUp()`. This sweeps release points across the dwell boundary and
    /// the whole warning window — where a tick and a release genuinely race
    /// against real `Task.sleep` timing, not a mocked clock — under real OS
    /// thread scheduling, with a generous post-release window for any
    /// in-flight continuation to surface. Across 80 runs it never did: zero
    /// violations, so a ramp tick re-tinting after release was ruled out as
    /// the cause of the lingering red (see task 10's artifact). `tickProgress()`
    /// additionally now guards on `isHolding` — flipped synchronously and
    /// first thing in `touchUp()` — so this is also a structural guarantee,
    /// not just an empirical one; this test is the regression guard for it.
    @Test("no ramp tick writes progress after touchUp, across the dwell boundary and warning window")
    func noRampTickAfterRelease() async {
        var maxViolationDelayMs: Double = 0
        var violationCount = 0
        var totalIterations = 0

        let releaseOffsetsMs: [Int] = [995, 1000, 1005, 1010, 1016, 1020, 1500, 1990, 2000, 2010]

        for offset in releaseOffsetsMs {
            for _ in 0..<8 {
                totalIterations += 1
                nonisolated(unsafe) var releasedAt: ContinuousClock.Instant?
                let clock = ContinuousClock()

                let controller = HoldToDiscardController(
                    onStop: {},
                    onDiscard: {},
                    onWarningRamp: { _ in
                        if let releasedAt {
                            let delay = clock.now - releasedAt
                            let ms = Double(delay.components.seconds) * 1000
                                + Double(delay.components.attoseconds) / 1_000_000_000_000_000
                            violationCount += 1
                            maxViolationDelayMs = max(maxViolationDelayMs, ms)
                        }
                    }
                )

                controller.touchDown()
                try? await Task.sleep(for: .milliseconds(offset))
                releasedAt = clock.now
                controller.touchUp()
                // Give any in-flight continuation a generous window to surface.
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        #expect(
            violationCount == 0,
            "a ramp tick fired after touchUp \(violationCount)/\(totalIterations) time(s), max delay \(maxViolationDelayMs)ms"
        )
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
