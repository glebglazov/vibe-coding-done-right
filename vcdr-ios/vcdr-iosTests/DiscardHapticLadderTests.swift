import Testing
import Foundation
@testable import vcdr_ios

@MainActor
struct DiscardHapticLadderTests {
    @Test("the dwell boundary itself gets a tick")
    func ticksAtDwellBoundary() {
        var ladder = DiscardHapticLadder()
        #expect(ladder.ticks(upTo: 0) == 1)
        #expect(ladder.ticks(upTo: 0) == 0)
    }

    @Test("nothing is owed before the ramp starts")
    func silentDuringDwell() {
        // The controller only reports ramp values after the dwell, so the only
        // way the ladder can be silent during it is by never being asked —
        // which is what the pill and ring do. Position 0 is the boundary.
        #expect(DiscardHapticLadder.tickPositions.first == 0)
    }

    @Test("ticks accelerate, ending near the fast end of the range")
    func cadenceAccelerates() {
        let duration = HoldToDiscardController.warningDuration
        let times = DiscardHapticLadder.tickPositions.map { Double($0) * duration }
        let gaps = zip(times.dropFirst(), times).map(-)

        #expect(gaps.count >= 5)
        for (later, earlier) in zip(gaps.dropFirst(), gaps) {
            #expect(later < earlier)
        }
        #expect(abs(gaps.first! - DiscardHapticLadder.startInterval) < 0.01)
        #expect(abs(gaps.last! - DiscardHapticLadder.endInterval) < 0.03)
    }

    @Test("a jump forward pays every tick it passed, once")
    func catchesUpWithoutRepeating() {
        var ladder = DiscardHapticLadder()
        let total = DiscardHapticLadder.tickPositions.count
        #expect(ladder.ticks(upTo: 1) == total)
        #expect(ladder.ticks(upTo: 1) == 0)
    }

    @Test("reset rewinds so the next hold starts from the boundary")
    func resetRewinds() {
        var ladder = DiscardHapticLadder()
        _ = ladder.ticks(upTo: 0.5)
        ladder.reset()
        #expect(ladder.ticks(upTo: 0) == 1)
    }
}
