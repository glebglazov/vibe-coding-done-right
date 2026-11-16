import Foundation
import Testing
@testable import vcdr_ios

@Suite("KeyboardChannel")
struct KeyboardChannelTests {
    @Test("decodes recording states and bundled result")
    func decodeState() {
        #expect(KeyboardChannel.decodeState("idle") == .idle)
        #expect(KeyboardChannel.decodeState("recording") == .recording)
        #expect(KeyboardChannel.decodeState("transcribing") == .transcribing)
        #expect(KeyboardChannel.decodeState("emptyResult") == .emptyResult)
        #expect(KeyboardChannel.decodeState("idle|hello world ") == .bundledResult("hello world "))
        #expect(KeyboardChannel.decodeState("unknown") == .idle)
    }

    @Test("all four terminal states are distinguishable on the wire")
    func terminalStatesAreDistinct() {
        // The point of the widened protocol: Empty Result, cancellation and a
        // Processing Failure are three different wire values, and none of them
        // is idle. A run's success is the fourth (a bundled result).
        let wireValues = [
            KeyboardChannel.encodeBundledResult("hello"),
            KeyboardChannel.RecordingState.emptyResult.rawValue,
            KeyboardChannel.RecordingState.cancelled.rawValue,
            KeyboardChannel.encodeFailure(reason: "Transcription unavailable: model load failed")
        ]
        #expect(Set(wireValues).count == wireValues.count)
        #expect(!wireValues.contains(KeyboardChannel.RecordingState.idle.rawValue))

        #expect(KeyboardChannel.decodeState(wireValues[0]) == .bundledResult("hello"))
        #expect(KeyboardChannel.decodeState(wireValues[1]) == .emptyResult)
        #expect(KeyboardChannel.decodeState(wireValues[2]) == .cancelled)
        #expect(
            KeyboardChannel.decodeState(wireValues[3])
                == .failed("Transcription unavailable: model load failed")
        )
    }

    @Test("encodes payload states with the same prefix scheme")
    func encodePayloadStates() {
        #expect(KeyboardChannel.encodeBundledResult("hello") == "idle|hello")
        #expect(KeyboardChannel.encodeFailure(reason: "mic seized") == "failed|mic seized")
        // A reason containing the separator survives — only the first `|` splits.
        #expect(KeyboardChannel.decodeState("failed|a|b") == .failed("a|b"))
        // A bare token stays a failure rather than degrading to idle.
        #expect(KeyboardChannel.decodeState("failed") == .failed(""))
    }

    @Test("failure reason route uses the existing app URL scheme")
    func failureReasonDeepLink() {
        #expect(KeyboardChannel.failureDeepLinkURL.scheme == "vcdr-ios")
        #expect(KeyboardChannel.failureDeepLinkURL.host == "failure")
    }

    @Test("publishes and reads state")
    func publishAndReadState() {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)

        channel.publish(.recording)
        #expect(channel.readState() == .recording)

        channel.publishBundledResult("done ")
        #expect(channel.readState() == .bundledResult("done "))

        channel.publishEmptyResult()
        #expect(channel.readState() == .emptyResult)

        channel.publish(.cancelled)
        #expect(channel.readState() == .cancelled)

        channel.publishFailure(reason: "Transcription failed: forced failure")
        #expect(channel.readState() == .failed("Transcription failed: forced failure"))
    }

    @Test("the keyboard consumes a rendered terminal state without notifying")
    func consumeStateIsSilent() {
        let defaults = makeDefaults()
        var notifications: [String] = []
        let channel = KeyboardChannel(defaults: defaults) { notifications.append($0) }

        channel.publishFailure(reason: "mic seized")
        notifications.removeAll()

        // The keyboard is the only reader; a post here would return to the same
        // process and cut short the flash it has just started rendering.
        channel.consumeState()
        #expect(channel.readState() == .idle)
        #expect(notifications.isEmpty)
    }

    @Test("heartbeat drives command versus URL action")
    func heartbeatDrivesAction() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, heartbeatFreshnessWindow: 18)

        #expect(channel.startRecording(now: fixedNow) == .openURL(KeyboardChannel.recordDeepLinkURL))

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-5))
        #expect(channel.startRecording(now: fixedNow) == .commandSent)
        #expect(channel.stopRecording(now: fixedNow) == .commandSent)

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-30))
        #expect(channel.stopRecording(now: fixedNow) == .openURL(KeyboardChannel.stopDeepLinkURL))
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
        #expect(channel.startRecording(now: fixedNow) == .openURL(KeyboardChannel.recordDeepLinkURL))
        #expect(channel.stopRecording(now: fixedNow) == .openURL(KeyboardChannel.stopDeepLinkURL))

        // Fail-closed teardown clears the Heartbeat (alive: false → 0); the
        // keyboard reads that as stale and still falls back to the deep link.
        channel.writeHeartbeat(alive: false, now: fixedNow)
        #expect(channel.startRecording(now: fixedNow) == .openURL(KeyboardChannel.recordDeepLinkURL))
        #expect(channel.stopRecording(now: fixedNow) == .openURL(KeyboardChannel.stopDeepLinkURL))

        // Only a beat inside the freshness window earns the fast Darwin path.
        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-1))
        #expect(channel.startRecording(now: fixedNow) == .commandSent)
    }

    @Test("command is read once")
    func commandReadOnce() {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)

        channel.send(.startRecording)

        #expect(channel.readAndClearCommand() == .startRecording)
        #expect(channel.readAndClearCommand() == nil)
    }

    @Test("cancel command carries a wall-clock stamp read back by the app")
    func cancelRecordingWritesCommandAndStamp() {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)
        let fixedNow = Date(timeIntervalSince1970: 1_000)

        channel.cancelRecording(now: fixedNow)

        #expect(channel.readAndClearCommand() == .cancelRecording)
        #expect(channel.isCancelStampFresh(now: fixedNow))
    }

    @Test("a cancel stamp inside the freshness window is applied, an older one is dropped")
    func cancelStampFreshnessWindow() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, cancelFreshnessWindow: 10)

        channel.cancelRecording(now: fixedNow.addingTimeInterval(-9))
        #expect(channel.isCancelStampFresh(now: fixedNow))

        channel.cancelRecording(now: fixedNow.addingTimeInterval(-11))
        #expect(!channel.isCancelStampFresh(now: fixedNow))
    }

    @Test("a stale cancel is dropped for good and cannot affect a later run")
    func staleCancelStampIsClearedNotJustRejected() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, cancelFreshnessWindow: 10)

        channel.cancelRecording(now: fixedNow.addingTimeInterval(-30))
        #expect(!channel.isCancelStampFresh(now: fixedNow))

        // Re-checking later must not resurrect the same stale stamp against
        // whatever Recording Run is active by then — it was cleared, not just
        // rejected once.
        #expect(!channel.isCancelStampFresh(now: fixedNow.addingTimeInterval(60)))
    }

    @Test("notifications are emitted for command and state writes")
    func notificationNames() {
        let defaults = makeDefaults()
        var notifications: [String] = []
        let channel = KeyboardChannel(defaults: defaults) { notifications.append($0) }

        channel.send(.stopRecording)
        channel.publish(.transcribing)

        #expect(notifications == [
            "glebglazov.vcdr-ios.command",
            "glebglazov.vcdr-ios.stateChanged"
        ])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "KeyboardChannelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
