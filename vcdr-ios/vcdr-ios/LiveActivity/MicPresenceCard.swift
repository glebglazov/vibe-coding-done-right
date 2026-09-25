import Foundation

@MainActor
protocol MicPresence: AnyObject {
    func reachabilityChanged(_ reachable: Bool)
}

@MainActor
protocol RecordingRunPresence: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func runChanged(_ run: MicPresenceRun?)
    func sceneChanged(foreground: Bool)
    /// Waits for every enqueued render, then reports whether ActivityKit holds
    /// a live card.
    func isShowingCard() async -> Bool
}

@MainActor
final class MicPresenceCard: MicPresence, RecordingRunPresence {
    static let renewInterval = HotMicSession.heartbeatInterval

    private let controller: HotMicActivityController
    private let clock: HotMicClock
    private let now: () -> Date
    private var reachable = false
    private var foreground = false
    private var run: MicPresenceRun?
    private var renewTask: Task<Void, Never>?
    private var outcomeLapseTask: Task<Void, Never>?

    init(controller: HotMicActivityController, clock: HotMicClock, now: @escaping () -> Date) {
        self.controller = controller
        self.clock = clock
        self.now = now
    }

    deinit {
        renewTask?.cancel()
        outcomeLapseTask?.cancel()
    }

    var areActivitiesEnabled: Bool { controller.areActivitiesEnabled }

    func reachabilityChanged(_ reachable: Bool) {
        self.reachable = reachable
        reconcile()
    }

    func sceneChanged(foreground: Bool) {
        self.foreground = foreground
        reconcile()
    }

    func runChanged(_ run: MicPresenceRun?) {
        self.run = run
        scheduleOutcomeLapse()
        reconcile()
    }

    func isShowingCard() async -> Bool {
        await controller.settled()
        return controller.holdsLiveCard
    }

    private func reconcile() {
        let decision = MicPresenceCardPolicy.decide(
            reachable: reachable,
            foreground: foreground,
            run: run,
            now: now()
        )
        controller.render(decision)
        if case .live = decision {
            keepRenewing()
        } else {
            renewTask?.cancel()
            renewTask = nil
        }
    }

    private func keepRenewing() {
        guard renewTask == nil else { return }
        renewTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                await clock.sleep(for: Self.renewInterval)
                guard !Task.isCancelled, let self else { return }
                self.reconcile()
            }
        }
    }

    private func scheduleOutcomeLapse() {
        outcomeLapseTask?.cancel()
        outcomeLapseTask = nil
        guard case .concluded(_, let until) = run else { return }
        let remaining = max(until.timeIntervalSince(now()), 0)
        outcomeLapseTask = Task { [weak self, clock] in
            await clock.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.reconcile()
        }
    }
}
