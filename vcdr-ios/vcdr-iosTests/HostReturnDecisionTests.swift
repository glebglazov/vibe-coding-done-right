import Foundation
import Testing
@testable import vcdr_ios

struct HostReturnDecisionTests {
    private static let arrivedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    private static let muxify = HostBundleID("dev.muxify.app")!

    private func seen(_ bundleID: String, secondsAfterArrival offset: TimeInterval = 0) -> HostAppSourceState {
        .observing(latest: HostObservation(
            host: HostBundleID(bundleID)!,
            observedAt: Self.arrivedAt.addingTimeInterval(offset)
        ))
    }

    private func step(
        _ source: HostAppSourceState,
        run: HostReturnRunProgress,
        deadlinePassed: Bool = false
    ) -> HostReturnStep {
        HostReturnDecision.step(
            for: HostReturnInputs(source: source, run: run, deadlinePassed: deadlinePassed),
            arrivedAt: Self.arrivedAt
        )
    }

    @Test("a fresh Muxify host and a Capturing run send the user back")
    func returnsWhenCapturing() {
        #expect(step(seen("dev.muxify.app", secondsAfterArrival: 0.6), run: .capturing) == .open(Self.muxify))
    }

    @Test("the app does not leave while the run is still Arming")
    func waitsDuringArming() {
        #expect(step(seen("dev.muxify.app"), run: .arming) == .wait)
    }

    @Test("Arming past the deadline keeps the user in VCDR")
    func armingPastDeadline() {
        #expect(step(seen("dev.muxify.app"), run: .arming, deadlinePassed: true) == .stay(.notCapturing))
    }

    @Test("a host seen shortly before the deep link still counts")
    func lookBackAcceptsRecentHost() {
        #expect(step(seen("dev.muxify.app", secondsAfterArrival: -4), run: .capturing) == .open(Self.muxify))
    }

    @Test("a host from an earlier keyboard use is not this deep link's host")
    func staleHostIsIgnored() {
        let stale = seen("dev.muxify.app", secondsAfterArrival: -30)
        #expect(step(stale, run: .capturing) == .wait)
        #expect(step(stale, run: .capturing, deadlinePassed: true) == .stay(.hostUnknown))
    }

    @Test("no host by the deadline keeps the user in VCDR")
    func noHostByDeadline() {
        #expect(step(.observing(latest: nil), run: .capturing) == .wait)
        #expect(step(.observing(latest: nil), run: .capturing, deadlinePassed: true) == .stay(.hostUnknown))
    }

    @Test("a missing private API keeps the user in VCDR at once")
    func apiMissing() {
        #expect(step(.inert, run: .arming) == .stay(.apiMissing))
    }

    @Test("any app the source names is a host to return to, with no list of apps")
    func anyHostReturns() {
        let host = HostBundleID("com.example.unknown")!
        #expect(step(seen("com.example.unknown"), run: .capturing) == .open(host))
    }

    @Test("Stop or Cancel before the return cancels it")
    func endedRunCancels() {
        #expect(step(seen("dev.muxify.app"), run: .ended) == .stay(.runEnded))
    }
}
