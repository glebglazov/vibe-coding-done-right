import Foundation
import Testing
@testable import vcdr_ios

@Suite("KeyboardReachabilityMonitor")
@MainActor
struct KeyboardReachabilityMonitorTests {

    /// Fast enough that a test doesn't wait on the shipping 2s cadence.
    private static let testInterval: Duration = .milliseconds(20)

    /// Waits for `condition`, or gives up — a poll that never lands is the
    /// failure, so the timeout is generous against the interval above.
    private func settle(
        within timeout: Duration = .milliseconds(600),
        until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: Self.testInterval)
        }
    }

    @Test("lights the control the moment it starts, before any poll tick")
    func samplesOnStart() {
        let channel = FakeKeyboardChannel()
        channel.writeHeartbeat(alive: true)
        let monitor = KeyboardReachabilityMonitor(channel: channel, pollInterval: Self.testInterval)

        #expect(monitor.recordsInPlace == false)
        monitor.start()
        #expect(monitor.recordsInPlace)
    }

    @Test("follows the heartbeat both ways while the keyboard is on screen")
    func tracksHeartbeatWhileVisible() async {
        let channel = FakeKeyboardChannel()
        channel.writeHeartbeat(alive: false)
        let monitor = KeyboardReachabilityMonitor(channel: channel, pollInterval: Self.testInterval)
        monitor.start()
        defer { monitor.stop() }

        #expect(monitor.recordsInPlace == false)

        // The app comes back while the keyboard stays up: no dismiss-and-reopen
        // is needed for the control to light.
        channel.writeHeartbeat(alive: true)
        await settle { monitor.recordsInPlace }
        #expect(monitor.recordsInPlace)

        // And it goes dark again when the heartbeat goes stale.
        channel.writeHeartbeat(alive: false)
        await settle { !monitor.recordsInPlace }
        #expect(monitor.recordsInPlace == false)
    }

    @Test("stops polling when the keyboard leaves the screen")
    func stopsPollingWhenHidden() async {
        let channel = FakeKeyboardChannel()
        channel.writeHeartbeat(alive: false)
        let monitor = KeyboardReachabilityMonitor(channel: channel, pollInterval: Self.testInterval)
        monitor.start()
        #expect(monitor.isPolling)

        monitor.stop()
        #expect(monitor.isPolling == false)

        let readsWhenStopped = channel.interactions.filter(\.isAliveProbe).count
        channel.writeHeartbeat(alive: true)
        await settle { channel.interactions.filter(\.isAliveProbe).count > readsWhenStopped }

        #expect(channel.interactions.filter(\.isAliveProbe).count == readsWhenStopped)
        #expect(monitor.recordsInPlace == false)
    }

    @Test("asks the heartbeat the same question the tap asks, and nothing else")
    func probesOnlyTheTapPredicate() async {
        let channel = FakeKeyboardChannel()
        channel.writeHeartbeat(alive: true)
        let monitor = KeyboardReachabilityMonitor(channel: channel, pollInterval: Self.testInterval)
        monitor.start()
        await settle { channel.interactions.filter(\.isAliveProbe).count >= 2 }
        monitor.stop()

        let probes = channel.interactions.filter { !$0.isHeartbeatWrite }
        #expect(probes.filter { !$0.isAliveProbe }.isEmpty)
        #expect(probes.count >= 2)
    }
}

private extension FakeKeyboardChannel.Interaction {
    var isAliveProbe: Bool {
        if case .isAppLikelyAlive = self { return true }
        return false
    }

    var isHeartbeatWrite: Bool {
        if case .writeHeartbeat = self { return true }
        return false
    }
}
