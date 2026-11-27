import Foundation
import Testing
@testable import vcdr_ios

@Suite("KeyboardChannel")
struct KeyboardChannelTests {
    @Test("deep links carry their command, and the stop link its run")
    func deepLinksRoundTrip() throws {
        let command = CommandID()
        let run = RunID()

        let record = try #require(KeyboardDeepLink.record(command).url)
        let stop = try #require(KeyboardDeepLink.stop(command, run: run).url)
        #expect(record.scheme == "vcdr-ios")
        #expect(record.host == "record")
        #expect(KeyboardDeepLink(url: record) == .record(command))
        #expect(KeyboardDeepLink(url: stop) == .stop(command, run: run))
    }

    @Test("a deep link without its command is not a deep link")
    func incompleteDeepLinksAreRejected() throws {
        #expect(KeyboardDeepLink(url: try #require(URL(string: "vcdr-ios://record"))) == nil)
        #expect(KeyboardDeepLink(url: try #require(URL(string: "vcdr-ios://stop?cmd=\(UUID().uuidString)"))) == nil)
        #expect(KeyboardDeepLink(url: try #require(URL(string: "other://record?cmd=\(UUID().uuidString)"))) == nil)
    }

    @Test("failure reason route uses the existing app URL scheme")
    func failureReasonDeepLink() throws {
        let url = try #require(KeyboardDeepLink.failure.url)
        #expect(url.scheme == "vcdr-ios")
        #expect(url.host == "failure")
        #expect(KeyboardDeepLink(url: url) == .failure)
    }

    @Test("the snapshot the app publishes is the snapshot the keyboard reads")
    func snapshotRoundTrip() {
        let defaults = makeDefaults()
        let app = KeyboardChannel(defaults: defaults)
        let keyboard = KeyboardChannel(defaults: defaults)
        let snapshot = KeyboardWireSnapshot(
            appSession: UUID(),
            seq: 3,
            run: KeyboardWireRun(id: RunID(), phase: .ended(.failed(reason: "mic seized"))),
            handledCommands: [CommandID()],
            writtenAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(keyboard.readSnapshot() == nil)
        app.publish(snapshot)
        #expect(keyboard.readSnapshot() == snapshot)
    }

    @Test("heartbeat drives command versus URL action")
    func heartbeatDrivesAction() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, heartbeatFreshnessWindow: 18)
        let run = RunID()

        guard case .openURL(.record) = channel.startRecording(now: fixedNow) else {
            Issue.record("Expected the record deep link with no Heartbeat")
            return
        }

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-5))
        guard case .commandSent = channel.startRecording(now: fixedNow),
              case .commandSent = channel.stopRecording(run, now: fixedNow) else {
            Issue.record("Expected Darwin commands with a fresh Heartbeat")
            return
        }

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-30))
        guard case .openURL(.stop(_, run: run)) = channel.stopRecording(run, now: fixedNow) else {
            Issue.record("Expected the stop deep link for the shown run with a stale Heartbeat")
            return
        }
    }

    @Test("stale heartbeat prefers Deep-Link Fallback over trusting visible readiness")
    func staleHeartbeatPrefersDeepLinkFallback() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, heartbeatFreshnessWindow: 18)

        // Mic Presence may still be advertising "Ready to record" (visible
        // readiness), but the keyboard trusts only the Heartbeat. A beat older
        // than the freshness window is stale and must route through the
        // Deep-Link Fallback — never a Darwin command that assumes the app is
        // listening.
        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-19))
        #expect(!channel.isAppLikelyAlive(now: fixedNow))
        #expect(isDeepLink(channel.startRecording(now: fixedNow)))

        // Fail-closed teardown clears the Heartbeat (alive: false → 0); the
        // keyboard reads that as stale and still falls back to the deep link.
        channel.writeHeartbeat(alive: false, now: fixedNow)
        #expect(isDeepLink(channel.startRecording(now: fixedNow)))

        // Only a beat inside the freshness window earns the fast Darwin path.
        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-1))
        #expect(!isDeepLink(channel.startRecording(now: fixedNow)))
        // A deep link never puts a command on the list: the URL carries it.
        #expect(channel.readCommands().count == 1)
    }

    @Test("commands queue in order, and one older than the retention drops off")
    func commandsQueueAndAgeOut() {
        let defaults = makeDefaults()
        let keyboard = KeyboardChannel(defaults: defaults)
        let app = KeyboardChannel(defaults: defaults)
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let run = RunID()
        keyboard.writeHeartbeat(alive: true, now: fixedNow)

        _ = keyboard.startRecording(now: fixedNow.addingTimeInterval(-KeyboardChannel.commandRetention - 1))
        keyboard.discardRecording(run, now: fixedNow.addingTimeInterval(-1))
        _ = keyboard.stopRecording(run, now: fixedNow)

        #expect(app.readCommands().map(\.kind) == [.discard(run), .stop(run)])
    }

    @Test("a command and a changed snapshot each post; a renewed snapshot does not")
    func notificationNames() {
        let defaults = makeDefaults()
        let posts = PostLog()
        let channel = KeyboardChannel(defaults: defaults, notify: { posts.append($0) })
        let snapshot = KeyboardWireSnapshot(
            appSession: UUID(), seq: 1, run: nil, handledCommands: [], writtenAt: Date()
        )

        channel.discardRecording(RunID())
        channel.publish(snapshot)
        channel.refresh(snapshot)

        #expect(posts.names == [
            "glebglazov.vcdr-ios.command",
            "glebglazov.vcdr-ios.stateChanged"
        ])
    }

    private func isDeepLink(_ action: KeyboardChannel.Action) -> Bool {
        if case .openURL = action { return true }
        return false
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyboardChannelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class PostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var names: [String] { lock.withLock { recorded } }

    func append(_ name: String) {
        lock.withLock { recorded.append(name) }
    }
}
