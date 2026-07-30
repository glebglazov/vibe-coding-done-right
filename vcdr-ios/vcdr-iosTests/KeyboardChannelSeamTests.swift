import Foundation
import Testing
@testable import vcdr_ios

@Suite("KeyboardChannel seam")
struct KeyboardChannelSeamTests {
    @Test("fake records publication command capture and heartbeat interactions")
    func fakeRecordsProtocolInteractions() {
        let fake = FakeKeyboardChannel()
        let channel: any KeyboardChannelProtocol = fake
        let now = Date(timeIntervalSince1970: 1_000)

        channel.publish(.recording)
        channel.publishBundledResult("done ")

        fake.enqueue(.startRecording)
        #expect(channel.readAndClearCommand() == .startRecording)
        #expect(channel.readAndClearCommand() == nil)
        channel.clearCommand()

        channel.replaceCaptures(["first", "second"])
        #expect(channel.readCaptures() == ["first", "second"])
        channel.clearCaptures()
        #expect(channel.readCaptures() == [])

        #expect(!channel.isAppLikelyAlive(now: now))
        channel.writeHeartbeat(alive: true, now: now.addingTimeInterval(-5))
        #expect(channel.isAppLikelyAlive(now: now))
        channel.writeHeartbeat(alive: true, now: now.addingTimeInterval(-30))
        #expect(!channel.isAppLikelyAlive(now: now))

        #expect(fake.interactions == [
            .publish(.recording),
            .publishBundledResult("done "),
            .readAndClearCommand,
            .readAndClearCommand,
            .clearCommand,
            .replaceCaptures(["first", "second"]),
            .readCaptures,
            .clearCaptures,
            .readCaptures,
            .isAppLikelyAlive(now: now),
            .writeHeartbeat(alive: true, now: now.addingTimeInterval(-5)),
            .isAppLikelyAlive(now: now),
            .writeHeartbeat(alive: true, now: now.addingTimeInterval(-30)),
            .isAppLikelyAlive(now: now)
        ])
    }

    @MainActor
    @Test("coordinator publishes through injected channel")
    func coordinatorUsesInjectedChannel() {
        let fake = FakeKeyboardChannel()
        let coordinator = RecordingFlowCoordinator(keyboardChannel: fake)

        coordinator.writeState(.recording)
        coordinator.cleanupStaleResults()

        #expect(fake.interactions == [
            .publish(.recording),
            .clearCommand,
            .publish(.idle)
        ])
    }

    @MainActor
    @Test("a keyboard stop with no Recording Run publishes the failure, never idle")
    func stopWithoutRunPublishesFailure() async {
        let fake = FakeKeyboardChannel()
        let coordinator = RecordingFlowCoordinator(keyboardChannel: fake)

        // Interrupted before audio started: no run exists, so no completion
        // adapter will report for it. The keyboard is mid-poll waiting for a
        // terminal state — it must get the failure, not an idle it would have
        // to interpret (ADR-0004).
        await coordinator.stopAndTranscribe(sendToKeyboard: true)

        let publishedFailures = fake.interactions.compactMap { interaction -> String? in
            guard case .publishFailure(let reason) = interaction else { return nil }
            return reason
        }
        #expect(publishedFailures == ["Recording was interrupted before audio started"])
        #expect(!fake.interactions.contains(.publish(.idle)))
    }
}
