import Testing
import Foundation
@testable import vcdr_ios

@MainActor
struct StatusRowContentTests {

    @Test("the resting hint carries a run that isn't being held")
    func restingHint() {
        #expect(
            StatusRowContent.resolve(warningProgress: nil, status: nil, holdAvailable: true)
                == StatusRowContent.restingHint
        )
    }

    @Test("nothing is said when no hold is possible and nothing is happening")
    func emptyAtRest() {
        #expect(StatusRowContent.resolve(warningProgress: nil, status: nil, holdAvailable: false) == nil)
    }

    @Test("the dwell says exactly what the resting row said")
    func dwellUnchanged() {
        // The controller reports no ramp before the dwell boundary, so a hold
        // in its dwell is indistinguishable here from no hold at all — which is
        // the whole point: the dwell shows nothing new.
        let dwell = StatusRowContent.resolve(warningProgress: nil, status: nil, holdAvailable: true)
        #expect(dwell == StatusRowContent.restingHint)
    }

    @Test("the warning names the escape hatch and counts the deadline down")
    func warningNarration() {
        let opening = StatusRowContent.resolve(warningProgress: 0, status: nil, holdAvailable: true)
        #expect(opening?.hasPrefix(StatusRowContent.releaseHint) == true)
        #expect(opening?.contains("2s") == true)

        let late = StatusRowContent.resolve(warningProgress: 0.9, status: nil, holdAvailable: true)
        #expect(late?.contains("1s") == true)
    }

    @Test("the countdown is derived from the controller's own window")
    func countdownDerivesFromController() {
        let window = HoldToDiscardController.warningDuration
        #expect(StatusRowContent.remainingSeconds(warningProgress: 0) == Int(window.rounded(.up)))
        // Monotonically non-increasing across the whole ramp, and never zero:
        // reaching zero *is* the threshold, by which point the warning is gone.
        var previous = Int.max
        for step in 0...100 {
            let remaining = StatusRowContent.remainingSeconds(warningProgress: CGFloat(step) / 100)
            #expect(remaining >= 1)
            #expect(remaining <= previous)
            previous = remaining
        }
        #expect(StatusRowContent.remainingSeconds(warningProgress: 1) == 1)
    }

    @Test("the countdown is clamped outside 0...1")
    func countdownClamped() {
        #expect(StatusRowContent.remainingSeconds(warningProgress: -1)
            == StatusRowContent.remainingSeconds(warningProgress: 0))
        #expect(StatusRowContent.remainingSeconds(warningProgress: 2)
            == StatusRowContent.remainingSeconds(warningProgress: 1))
    }

    @Test("hold narration outranks a transient status, which outranks the hint")
    func precedence() {
        #expect(
            StatusRowContent.resolve(warningProgress: 0.5, status: .transcribing, holdAvailable: true)
                == StatusRowContent.holdNarration(warningProgress: 0.5)
        )
        #expect(
            StatusRowContent.resolve(warningProgress: nil, status: .transcribing, holdAvailable: true)
                == TransientStatus.transcribing.text
        )
        #expect(
            StatusRowContent.resolve(warningProgress: nil, status: .noSpeechDetected, holdAvailable: false)
                == TransientStatus.noSpeechDetected.text
        )
    }

    @Test("the row is sized for every string it can hold")
    func sizingCoversEveryTenant() {
        let sizing = StatusRowContent.sizingTexts
        #expect(sizing.contains(StatusRowContent.restingHint))
        #expect(sizing.contains(StatusRowContent.holdNarration(warningProgress: 0)))
        for status in TransientStatus.allCases {
            #expect(sizing.contains(status.text))
        }
    }

    @Test("the countdown never widens the line as it ticks")
    func countdownKeepsOneWidth() {
        // Same character count at every ramp position: the digit changes, the
        // line's length does not, and the row renders it with monospaced
        // digits so the glyph widths match too.
        let lengths = Set((0...100).map {
            StatusRowContent.holdNarration(warningProgress: CGFloat($0) / 100).count
        })
        #expect(lengths.count == 1)
    }

    @Test("the app's empty-result error is recognised as the no-speech tenant")
    func emptyResultWording() {
        // The coordinator puts this exact string on its error state, so the
        // row's mapping and the coordinator can't drift apart.
        #expect(TransientStatus.noSpeechDetectedText == "No speech detected")
    }

    @Test("narration exists only while a hold is ramping")
    func narrationLifetime() {
        let narration = HoldNarrationState()
        #expect(narration.warningProgress == nil)
        narration.ramp(to: 0.4)
        #expect(narration.warningProgress == 0.4)
        narration.end()
        #expect(narration.warningProgress == nil)
    }

    @Test("the hint outlives the dwell and dies with the hold")
    func hintLifetime() {
        let narration = HoldNarrationState()
        #expect(narration.isHinting == false)

        // Hinting through the dwell, with nothing to narrate yet: the keyboard
        // shows the resting hint in place of its settings pills.
        narration.beginHint()
        #expect(narration.isHinting)
        #expect(narration.warningProgress == nil)

        narration.ramp(to: 0.4)
        #expect(narration.isHinting)

        narration.end()
        #expect(narration.isHinting == false)
        #expect(narration.warningProgress == nil)
    }
}
