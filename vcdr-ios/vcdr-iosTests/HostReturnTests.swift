import Foundation
import Observation
import Testing
@testable import vcdr_ios

@MainActor
@Observable
private final class FakeHostAppSource: HostAppSource {
    var state: HostAppSourceState = .observing(latest: nil)
    func start() {}
}

@MainActor
@Observable
private final class FakeRun {
    var progress: HostReturnRunProgress = .arming
}

@MainActor
struct HostReturnTests {
    private static let muxify = HostBundleID("dev.muxify.app")!

    @Test("a keyboard start opens Muxify by bundle ID once audio flows", .timeLimit(.minutes(1)))
    func returnsToMuxifyOnceCapturing() async {
        let source = FakeHostAppSource()
        let run = FakeRun()
        let (opened, openedSink) = AsyncStream.makeStream(of: HostBundleID.self)
        let hostReturn = HostReturn(
            source: source,
            runProgress: { run.progress },
            openApp: { host in
                openedSink.yield(host)
                return true
            }
        )

        hostReturn.recordDeepLinkArrived()
        source.state = .observing(latest: HostObservation(host: Self.muxify, observedAt: Date()))
        run.progress = .capturing

        var hosts = opened.makeAsyncIterator()
        #expect(await hosts.next() == Self.muxify)
    }
}
