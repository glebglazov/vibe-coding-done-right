import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("HotMicActivityController")
struct HotMicActivityControllerTests {

    /// The horizon every card is stamped with, in seconds.
    private let freshnessWindow = KeyboardChannel.heartbeatFreshnessWindow

    // MARK: - Tests

    @Test("two overlapping shows produce exactly one Live Activity")
    func overlappingShowsRequestOneActivity() async {
        let store = FakeActivityStore()
        store.parkRequests = true
        let controller = HotMicActivityController(store: store)
        await settle()

        async let first: Void = controller.start(recording: false)
        async let second: Void = controller.start(recording: false)
        // Park inside the ActivityKit request, then give the second caller every
        // chance to slip into the window the old ad-hoc guards left open.
        await waitUntil { store.parkedRequests == 1 }
        await settle()

        store.releaseRequests()
        _ = await (first, second)

        #expect(store.requestCalls == 1)
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("a hide that lands mid-show leaves no activity behind")
    func hideDuringShowLeavesNoOrphan() async {
        let store = FakeActivityStore()
        store.parkRequests = true
        let controller = HotMicActivityController(store: store)
        await settle()

        async let show: Void = controller.start(recording: false)
        await waitUntil { store.parkedRequests == 1 }
        async let hide: Void = controller.stop()
        await settle()

        store.releaseRequests()
        _ = await (show, hide)

        #expect(store.liveActivityIDs.isEmpty)
    }

    @Test("hiding ends strays the controller never requested")
    func hideEndsStrayActivities() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.start(recording: false)
        store.injectStray("stray-from-a-crashed-session")

        await controller.stop()

        #expect(store.liveActivityIDs.isEmpty)
        #expect(store.endedIDs.contains("stray-from-a-crashed-session"))
    }

    @Test("the launch sweep clears activities left by a previous process")
    func launchSweepClearsPreviousProcess() async {
        let store = FakeActivityStore()
        store.injectStray("survivor-of-the-last-launch")
        let controller = HotMicActivityController(store: store)

        await settle()

        #expect(store.liveActivityIDs.isEmpty)
        #expect(store.endedIDs == ["survivor-of-the-last-launch"])
        _ = controller
    }

    @Test("a shown card claims readiness exactly one heartbeat freshness window ahead")
    func staleHorizonIsTheHeartbeatFreshnessWindow() async {
        let store = FakeActivityStore()
        let shownAt = Date(timeIntervalSince1970: 1_000)
        let controller = HotMicActivityController(store: store, now: { shownAt })
        await settle()

        await controller.start(recording: false)

        // Same window the keyboard reads to choose between recording in place
        // and the deep-link bounce — one constant, so the card and the record
        // control cannot disagree.
        #expect(store.requestedStaleDates == [shownAt.addingTimeInterval(freshnessWindow)])
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("each refresh carries the horizon a full window past the beat that sent it")
    func refreshTracksTheHeartbeat() async {
        let store = FakeActivityStore()
        var fakeNow = Date(timeIntervalSince1970: 0)
        let controller = HotMicActivityController(store: store, now: { fakeNow })
        await settle()

        await controller.start(recording: false)

        fakeNow = Date(timeIntervalSince1970: 5)
        await controller.refresh(recording: false)
        fakeNow = Date(timeIntervalSince1970: 10)
        await controller.refresh(recording: false)

        #expect(store.updatedStaleDates == [
            Date(timeIntervalSince1970: 5 + freshnessWindow),
            Date(timeIntervalSince1970: 10 + freshnessWindow)
        ])
        // The card stays the one that was requested — refreshing never trades it.
        #expect(store.requestCalls == 1)
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("a refresh with no card on screen claims nothing")
    func refreshWithoutPresenceRequestsNothing() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.refresh(recording: false)

        #expect(store.requestCalls == 0)
        #expect(store.updatedStaleDates.isEmpty)
        #expect(store.liveActivityIDs.isEmpty)
    }

    @Test("the requested card carries the face it was shown with")
    func showCarriesTheRecordingFace() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.start(recording: true)

        #expect(store.requestedFaces == [true])
    }

    @Test("an on-screen card is re-stamped when the run starts and stops")
    func faceSwitchesOnTheCardAlreadyShown() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.start(recording: false)
        await controller.start(recording: true)
        await controller.refresh(recording: true)
        await controller.start(recording: false)

        // One card throughout — the face changes on it rather than by trading it
        // for a second one.
        #expect(store.requestCalls == 1)
        #expect(store.liveActivityIDs.count == 1)
        #expect(store.updatedFaces == [true, true, false])
    }

    @Test("presence stays silent when the user has disabled Live Activities")
    func disabledActivitiesRequestNothing() async {
        let store = FakeActivityStore()
        store.areActivitiesEnabled = false
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.start(recording: false)

        #expect(store.requestCalls == 0)
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
    var areActivitiesEnabled = true
    /// When true, `request()` suspends until `releaseRequests()`.
    var parkRequests = false

    private(set) var requestCalls = 0
    private(set) var endedIDs: [String] = []
    /// Stale horizons stamped on cards as they were requested and refreshed —
    /// how far into the future each call let the readiness claim reach.
    private(set) var requestedStaleDates: [Date] = []
    private(set) var updatedStaleDates: [Date] = []
    /// The face each request and update carried, in order.
    private(set) var requestedFaces: [Bool] = []
    private(set) var updatedFaces: [Bool] = []

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

    func request(recording: Bool, staleDate: Date) async -> String? {
        requestCalls += 1
        requestedStaleDates.append(staleDate)
        requestedFaces.append(recording)
        let id = "activity-\(requestCalls)"
        if parkRequests {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parked.append(cont)
            }
        }
        live.append(id)
        return id
    }

    func update(id: String, recording: Bool, staleDate: Date) async {
        updatedStaleDates.append(staleDate)
        updatedFaces.append(recording)
    }

    func end(id: String) async {
        endedIDs.append(id)
        live.removeAll { $0 == id }
    }
}
