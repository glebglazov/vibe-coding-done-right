import Foundation
import Testing
@testable import vcdr_ios

@MainActor
@Suite("HotMicActivityController")
struct HotMicActivityControllerTests {

    // MARK: - Tests

    @Test("two overlapping shows produce exactly one Live Activity")
    func overlappingShowsRequestOneActivity() async {
        let store = FakeActivityStore()
        store.parkRequests = true
        let controller = HotMicActivityController(store: store)
        await settle()

        async let first: Void = controller.start(deadline: nil)
        async let second: Void = controller.start(deadline: nil)
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

        async let show: Void = controller.start(deadline: nil)
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

        await controller.start(deadline: nil)
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

    @Test("a Presence Deadline schedules dismissal instead of ending the card now")
    func deadlineSchedulesDismissal() async {
        let store = FakeActivityStore()
        let controller = HotMicActivityController(store: store)
        await settle()
        let deadline = Date().addingTimeInterval(300)

        await controller.start(deadline: deadline)

        #expect(store.scheduledDismissals == [deadline])
        #expect(store.liveActivityIDs.count == 1)
    }

    @Test("presence stays silent when the user has disabled Live Activities")
    func disabledActivitiesRequestNothing() async {
        let store = FakeActivityStore()
        store.areActivitiesEnabled = false
        let controller = HotMicActivityController(store: store)
        await settle()

        await controller.start(deadline: nil)

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
    private(set) var updateCalls = 0
    private(set) var endedIDs: [String] = []
    /// Deadlines handed to `end(id:dismissingAt:)`, so a finite Presence
    /// Deadline can be told apart from an immediate dismissal.
    private(set) var scheduledDismissals: [Date] = []

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

    func request() async -> String? {
        requestCalls += 1
        let id = "activity-\(requestCalls)"
        if parkRequests {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parked.append(cont)
            }
        }
        live.append(id)
        return id
    }

    func update(id: String) async {
        updateCalls += 1
    }

    /// Mirrors iOS: a scheduled dismissal keeps the card on screen until its
    /// deadline, while an immediate one removes it now.
    func end(id: String, dismissingAt deadline: Date?) async {
        if let deadline {
            scheduledDismissals.append(deadline)
            return
        }
        endedIDs.append(id)
        live.removeAll { $0 == id }
    }
}
