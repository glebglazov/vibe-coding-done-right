import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("MicPresenceCard")
struct MicPresenceCardTests {
    private let since = Date(timeIntervalSince1970: 900)

    @MainActor
    private final class Env {
        let store = FakeActivityStore()
        let clock = TestClock()
        var now = Date(timeIntervalSince1970: 1_000)
        private(set) lazy var card = MicPresenceCard(
            controller: HotMicActivityController(store: store, now: { [unowned self] in self.now }),
            clock: clock,
            now: { [unowned self] in self.now }
        )

        func settle() async {
            _ = await card.isShowingCard()
            for _ in 0..<10 { await Task.yield() }
        }
    }

    @Test("a background run shows its phase and the card renews it while live")
    func runPhaseRenews() async {
        let env = Env()
        env.card.runChanged(.active(origin: .shortcut, phase: .arming))
        await env.settle()
        #expect(env.store.requestedFaces == [.arming])

        env.now = env.now.addingTimeInterval(5)
        env.clock.advance()
        await env.settle()

        #expect(env.store.updatedFaces == [.arming])
        #expect(env.store.updatedStaleDates == [env.now.addingTimeInterval(KeyboardChannel.heartbeatFreshnessWindow)])
        #expect(await env.card.isShowingCard())
    }

    @Test("losing reachability while Capturing keeps the Capturing face")
    func capturingOutlivesReachability() async {
        let env = Env()
        env.card.reachabilityChanged(true)
        env.card.runChanged(.active(origin: .keyboard, phase: .capturing(since: since)))
        env.card.reachabilityChanged(false)
        await env.settle()

        #expect(env.store.updatedFaces.last == .capturing(since: since))
        #expect(env.store.endedIDs.isEmpty)
    }

    @Test("an outcome face falls back to Ready when its dwell ends while reachable")
    func outcomeLapsesToReady() async {
        let env = Env()
        env.card.reachabilityChanged(true)
        let until = env.now.addingTimeInterval(MicPresenceCardPolicy.concludedDwell)
        env.card.runChanged(.concluded(.copied, until: until))
        await env.settle()
        #expect(env.store.updatedFaces.last == .concluded(.copied))

        env.now = until
        env.clock.advance()
        await env.settle()

        #expect(env.store.updatedFaces.last == .ready)
    }

    @Test("an outcome with no warm session freezes the card until its dwell ends")
    func outcomeWithoutReachabilityFreezes() async {
        let env = Env()
        env.card.runChanged(.active(origin: .shortcut, phase: .finalizing))
        let until = env.now.addingTimeInterval(MicPresenceCardPolicy.concludedDwell)
        env.card.runChanged(.concluded(.copied, until: until))
        await env.settle()

        #expect(env.store.concluded == [.init(id: "activity-1", state: .concluded(.copied), dismissAt: until)])
        #expect(!(await env.card.isShowingCard()))
    }

    @Test("a hidden card stops renewing")
    func hiddenStopsRenewing() async {
        let env = Env()
        env.card.reachabilityChanged(true)
        await env.settle()
        env.card.reachabilityChanged(false)
        await env.settle()
        let updatesWhenHidden = env.store.updatedFaces.count

        env.clock.advance()
        await env.settle()

        #expect(env.store.updatedFaces.count == updatesWhenHidden)
        #expect(env.store.liveActivityIDs.isEmpty)
    }

    @Test("VCDR on screen hides a keyboard run's card and keeps a Shortcut run's")
    func foregroundRule() async {
        let env = Env()
        env.card.sceneChanged(foreground: true)
        env.card.runChanged(.active(origin: .keyboard, phase: .arming))
        await env.settle()
        #expect(env.store.requestCalls == 0)

        env.card.runChanged(nil)
        env.card.runChanged(.active(origin: .shortcut, phase: .arming))
        await env.settle()
        #expect(env.store.requestedFaces == [.arming])
    }
}
