import Foundation
import Testing
@testable import vcdr_ios

/// A scene reconnect or a second intent must not run the launch sequence again.
@MainActor
struct AppBootTests {
    @Test("launching twice runs the prefix once and the deferred boot once")
    func launchIsIdempotent() async {
        var prefixRuns = 0
        var deferredRuns = 0
        let boot = AppBoot(steps: AppBoot.Steps(
            prefix: { prefixRuns += 1 },
            deferred: { deferredRuns += 1 }
        ))

        boot.launch()
        #expect(prefixRuns == 1)
        boot.launch()
        for _ in 0..<10 { await Task.yield() }

        #expect(prefixRuns == 1)
        #expect(deferredRuns == 1)
    }
}
