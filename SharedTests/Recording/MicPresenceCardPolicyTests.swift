import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

struct MicPresenceCardPolicyTests {
    private static let now = Date(timeIntervalSince1970: 10_000)
    private static let since = now.addingTimeInterval(-7)
    private static let until = now.addingTimeInterval(MicPresenceCardPolicy.concludedDwell)

    private func decide(
        reachable: Bool = false,
        foreground: Bool = false,
        _ run: MicPresenceRun?
    ) -> MicPresenceCardDecision {
        MicPresenceCardPolicy.decide(reachable: reachable, foreground: foreground, run: run, now: Self.now)
    }

    @Test("with no run the card is Ready exactly while reachable in the background")
    func idle() {
        #expect(decide(reachable: true, nil) == .live(.ready))
        #expect(decide(reachable: false, nil) == .hidden)
        #expect(decide(reachable: true, foreground: true, nil) == .hidden)
    }

    @Test("a background run shows its phase whether or not the Hot Mic Session is warm", arguments: [true, false])
    func backgroundPhases(reachable: Bool) {
        #expect(decide(reachable: reachable, .active(origin: .keyboard, phase: .arming)) == .live(.arming(cardStops: true)))
        #expect(decide(reachable: reachable, .active(origin: .app, phase: .capturing(since: Self.since)))
            == .live(.capturing(since: Self.since, cardStops: true)))
        #expect(decide(reachable: reachable, .active(origin: .shortcut, phase: .finalizing)) == .live(.finalizing))
    }

    @Test("a Shortcut run keeps its card on screen while Arming and Capturing, with no button")
    func shortcutInForeground() {
        #expect(decide(foreground: true, .active(origin: .shortcut, phase: .arming)) == .live(.arming(cardStops: false)))
        #expect(decide(foreground: true, .active(origin: .shortcut, phase: .capturing(since: Self.since)))
            == .live(.capturing(since: Self.since, cardStops: false)))
        #expect(decide(foreground: true, .active(origin: .shortcut, phase: .finalizing)) == .hidden)
    }

    @Test("a keyboard or app run has no card while VCDR is on screen")
    func otherOriginsInForeground() {
        #expect(decide(reachable: true, foreground: true, .active(origin: .keyboard, phase: .capturing(since: Self.since)))
            == .hidden)
        #expect(decide(reachable: true, foreground: true, .active(origin: .app, phase: .arming)) == .hidden)
    }

    @Test("a cancel in flight shows the same card as no run")
    func cancellingArming() {
        #expect(decide(reachable: true, .active(origin: .shortcut, phase: .cancellingArming)) == .live(.ready))
        #expect(decide(reachable: false, .active(origin: .shortcut, phase: .cancellingArming)) == .hidden)
        #expect(decide(foreground: true, .active(origin: .shortcut, phase: .cancellingArming)) == .hidden)
    }

    @Test("an outcome stays live while a warm session renews it, and is frozen until its dwell ends otherwise")
    func concluded() {
        let run = MicPresenceRun.concluded(.transcribed, until: Self.until)
        #expect(decide(reachable: true, run) == .live(.concluded(.transcribed)))
        #expect(decide(reachable: false, run) == .concluding(.concluded(.transcribed), dismissAt: Self.until))
        #expect(decide(reachable: true, foreground: true, run) == .hidden)
    }

    @Test("an outcome whose dwell has passed counts as no run")
    func concludedExpired() {
        let run = MicPresenceRun.concluded(.failed, until: Self.now)
        #expect(decide(reachable: true, run) == .live(.ready))
        #expect(decide(reachable: false, run) == .hidden)
    }
}
