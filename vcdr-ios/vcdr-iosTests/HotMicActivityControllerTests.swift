import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("HotMicActivityController")
struct HotMicActivityControllerTests {

    /// The horizon every card is stamped with, in seconds.
    private let freshnessWindow = KeyboardChannel.heartbeatFreshnessWindow
    private let since = Date(timeIntervalSince1970: 500)

    // MARK: - Tests

    @Test("two overlapping live renders produce exactly one Live Activity")
    func overlappingRendersRequestOneActivity() async {
        let store = FakeActivityStore()
        store.parkRequests = true
        let controller = HotMicActivityController(store: store)
        await settle()

        let first = controller.render(.live(.ready))
        let second = controller.render(.live(.ready))
        await waitUntil { store.parkedRequests == 1 }
        await settle()

        store.releaseRequests()
        await first.value
        await second.value

        #expect(store.requestCalls == 1)
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("a hidden render that lands mid-request leaves no activity behind")
    func hideDuringShowLeavesNoOrphan() async {
        let store = FakeActivityStore()
        store.parkRequests = true
        let controller = HotMicActivityController(store: store)
        await settle()

        let show = controller.render(.live(.ready))
        await waitUntil { store.parkedRequests == 1 }
        let hide = controller.render(.hidden)
        await settle()

        store.releaseRequests()
        await show.value
        await hide.value

        #expect(store.liveActivityIDs.isEmpty)
        #expect(!controller.holdsLiveCard)
    }

    @Test("hiding ends strays the controller never requested")
    func hideEndsStrayActivities() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.render(.live(.ready)).value
        store.injectStray("stray-from-a-crashed-session")

        await controller.render(.hidden).value

        #expect(store.liveActivityIDs.isEmpty)
        #expect(store.endedIDs.contains("stray-from-a-crashed-session"))
    }

    @Test("the launch sweep clears activities left by a previous process")
    func launchSweepClearsPreviousProcess() async {
        let store = FakeActivityStore()
        store.injectStray("survivor-of-the-last-launch")
        let controller = HotMicActivityController(store: store)

        await controller.settled()

        #expect(store.liveActivityIDs.isEmpty)
        #expect(store.endedIDs == ["survivor-of-the-last-launch"])
    }

    @Test("a live card claims its face exactly one heartbeat freshness window ahead")
    func staleHorizonIsTheHeartbeatFreshnessWindow() async {
        let store = FakeActivityStore()
        let shownAt = Date(timeIntervalSince1970: 1_000)
        let controller = HotMicActivityController(store: store, now: { shownAt })
        await settle()

        await controller.render(.live(.ready)).value

        // Same window the keyboard reads to choose between recording in place
        // and the deep-link bounce — one constant, so the card and the record
        // control cannot disagree.
        #expect(store.requestedStaleDates == [shownAt.addingTimeInterval(freshnessWindow)])
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("each re-render carries the horizon a full window past the moment it was sent")
    func rerenderRenewsTheHorizon() async {
        let store = FakeActivityStore()
        var fakeNow = Date(timeIntervalSince1970: 0)
        let controller = HotMicActivityController(store: store, now: { fakeNow })
        await settle()

        await controller.render(.live(.ready)).value
        fakeNow = Date(timeIntervalSince1970: 5)
        await controller.render(.live(.ready)).value
        fakeNow = Date(timeIntervalSince1970: 10)
        await controller.render(.live(.ready)).value

        #expect(store.updatedStaleDates == [
            Date(timeIntervalSince1970: 5 + freshnessWindow),
            Date(timeIntervalSince1970: 10 + freshnessWindow)
        ])
        #expect(store.requestCalls == 1)
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("a run's faces change on the one card already on screen")
    func facesChangeOnTheCardAlreadyShown() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.render(.live(.arming)).value
        await controller.render(.live(.capturing(since: since))).value
        await controller.render(.live(.finalizing)).value

        #expect(store.requestedFaces == [.arming])
        #expect(store.updatedFaces == [.capturing(since: since), .finalizing])
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("a concluding render freezes the held card on its outcome until its dismissal")
    func concludingFreezesTheCard() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        let dismissAt = Date(timeIntervalSince1970: 2_000)
        await settle()

        await controller.render(.live(.finalizing)).value
        await controller.render(.concluding(.concluded(.copied), dismissAt: dismissAt)).value

        #expect(store.concluded == [.init(id: "activity-1", state: .concluded(.copied), dismissAt: dismissAt)])
        #expect(!controller.holdsLiveCard)
    }

    @Test("a live render after a concluded card ends it before requesting a new one")
    func liveAfterConcludingReplacesTheFrozenCard() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.render(.live(.finalizing)).value
        await controller.render(.concluding(.concluded(.copied), dismissAt: .distantFuture)).value
        await controller.render(.live(.arming)).value

        #expect(store.endedIDs == ["activity-1"])
        #expect(store.liveActivityIDs == ["activity-2"])
        #expect(controller.holdsLiveCard)
    }

    @Test("a concluding render with no card on screen requests nothing")
    func concludingWithoutACardRequestsNothing() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.render(.concluding(.concluded(.failed), dismissAt: .distantFuture)).value

        #expect(store.requestCalls == 0)
        #expect(store.concluded.isEmpty)
    }

    @Test("presence stays silent when the user has disabled Live Activities")
    func disabledActivitiesRequestNothing() async {
        let store = FakeActivityStore()
        store.areActivitiesEnabled = false
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.render(.live(.ready)).value

        #expect(store.requestCalls == 0)
        #expect(!controller.holdsLiveCard)
    }

    // MARK: - Helpers

    /// Lets enqueued MainActor jobs (the operation chain, resumed requests) run
    /// to a quiescent point before asserting.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Polls a condition across MainActor turns — robust against how many hops
    /// a resumed continuation needs before its effect is observable.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }
}

// MARK: - Test doubles

/// In-memory stand-in for ActivityKit. `request()` can be parked so a test holds
/// a show mid-flight and drives a second operation at the exact window that used
/// to let two Live Activities exist at once.
@MainActor
final class FakeActivityStore: HotMicActivityStore {
    struct Conclusion: Equatable {
        let id: String
        let state: MicPresenceCardState
        let dismissAt: Date
    }

    var areActivitiesEnabled = true
    /// When true, `request()` suspends until `releaseRequests()`.
    var parkRequests = false

    private(set) var requestCalls = 0
    private(set) var endedIDs: [String] = []
    private(set) var requestedStaleDates: [Date] = []
    private(set) var updatedStaleDates: [Date] = []
    /// The face each request and update carried, in order.
    private(set) var requestedFaces: [MicPresenceCardState] = []
    private(set) var updatedFaces: [MicPresenceCardState] = []
    private(set) var concluded: [Conclusion] = []

    private var live: [String] = []
    private var parked: [CheckedContinuation<Void, Never>] = []

    var liveActivityIDs: [String] { live }
    var parkedRequests: Int { parked.count }

    /// Plants a card the controller never asked for — what a crashed process
    /// leaves behind.
    func injectStray(_ id: String) { live.append(id) }

    func releaseRequests() {
        let waiting = parked
        parked.removeAll()
        waiting.forEach { $0.resume() }
    }

    func request(state: MicPresenceCardState, staleDate: Date) async -> String? {
        requestCalls += 1
        requestedStaleDates.append(staleDate)
        requestedFaces.append(state)
        let id = "activity-\(requestCalls)"
        if parkRequests {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parked.append(cont)
            }
        }
        live.append(id)
        return id
    }

    func update(id: String, state: MicPresenceCardState, staleDate: Date) async {
        updatedStaleDates.append(staleDate)
        updatedFaces.append(state)
    }

    func end(id: String) async {
        endedIDs.append(id)
        live.removeAll { $0 == id }
    }

    /// A concluded card stays in the system's list until its dismissal, as a
    /// frozen activity does.
    func conclude(id: String, state: MicPresenceCardState, dismissAt: Date) async {
        concluded.append(Conclusion(id: id, state: state, dismissAt: dismissAt))
    }
}
