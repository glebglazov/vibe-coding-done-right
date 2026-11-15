import Foundation
import Observation
import OSLog

/// Sends the user back to the app they were typing in after the keyboard's
/// Deep-Link Fallback opened VCDR to record. The Recording Run keeps
/// Capturing in the background, so the next keyboard tap stops it in place.
/// Every path that does not return leaves the user in VCDR, as before.
@MainActor
@Observable
final class HostReturn {
    // MARK: - Constants

    private static let millisecondsPerSecond: Double = 1000

    @ObservationIgnored private let source: any HostAppSource
    @ObservationIgnored private let runProgress: @MainActor () -> HostReturnRunProgress
    @ObservationIgnored private let openApp: @MainActor (HostBundleID) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var attempt: Task<Void, Never>?
    private var deadlinePassed = false

    init(
        source: any HostAppSource,
        runProgress: @escaping @MainActor () -> HostReturnRunProgress,
        openApp: @escaping @MainActor (HostBundleID) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.runProgress = runProgress
        self.openApp = openApp
        self.now = now
    }

    isolated deinit {
        attempt?.cancel()
    }

    /// Call when the `record` deep link arrives, after the coordinator has
    /// marked the run Arming. A repeated link joins the attempt in flight.
    func recordDeepLinkArrived() {
        guard attempt == nil else {
            Logger.app.info("Host Return: an attempt is already in flight")
            return
        }
        let arrivedAt = now()
        deadlinePassed = false
        attempt = Task { [weak self] in
            await self?.run(arrivedAt: arrivedAt)
            self?.attempt = nil
        }
    }

    private func run(arrivedAt: Date) async {
        let deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: HostReturnDecision.deadline)) != nil else { return }
            self?.deadlinePassed = true
        }
        defer { deadline.cancel() }

        let inputs = Observations { @MainActor [self] in
            HostReturnInputs(source: source.state, run: runProgress(), deadlinePassed: deadlinePassed)
        }
        for await current in inputs {
            let outcome: HostReturnOutcome
            switch HostReturnDecision.step(for: current, arrivedAt: arrivedAt) {
            case .wait:
                continue
            case .stay(let stayed):
                outcome = stayed
            case .open(let host):
                outcome = openApp(host) ? .returned : .openFailed
            }
            let host = HostReturnDecision.freshHost(in: current.source, arrivedAt: arrivedAt)
            let waitedMs = Int(now().timeIntervalSince(arrivedAt) * Self.millisecondsPerSecond)
            Logger.app.notice(
                "Host Return host=\(host?.rawValue ?? "none") outcome=\(outcome.rawValue) runPhase=\(current.run.rawValue) waitedMs=\(waitedMs)"
            )
            return
        }
    }
}
