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

    @Test("encodes bundled result on idle state channel")
    func encodeBundledResult() {
        #expect(KeyboardChannel.encodeBundledResult("hello") == "idle|hello")
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
    }

    @Test("captures roundtrip through JSON storage")
    func capturesRoundtrip() {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)

        channel.replaceCaptures(["first"])
        channel.appendCapture("second")

        #expect(channel.readCaptures() == ["first", "second"])

        channel.clearCaptures()
        #expect(channel.readCaptures() == [])
    }

    @Test("heartbeat drives command versus URL action")
    func heartbeatDrivesAction() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 1_000)
        let channel = KeyboardChannel(defaults: defaults, heartbeatFreshnessWindow: 18)

        #expect(channel.startRecording(captures: [], now: fixedNow) == .openURL(KeyboardChannel.recordDeepLinkURL))

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-5))
        #expect(channel.startRecording(captures: [], now: fixedNow) == .commandSent)
        #expect(channel.stopRecording(now: fixedNow) == .commandSent)

        channel.writeHeartbeat(alive: true, now: fixedNow.addingTimeInterval(-30))
        #expect(channel.stopRecording(now: fixedNow) == .openURL(KeyboardChannel.stopDeepLinkURL))
    }

    @Test("command is read once")
    func commandReadOnce() {
        let defaults = makeDefaults()
        let channel = KeyboardChannel(defaults: defaults)

        channel.send(.startRecording)

        #expect(channel.readAndClearCommand() == .startRecording)
        #expect(channel.readAndClearCommand() == nil)
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
