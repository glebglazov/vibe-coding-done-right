import Foundation
import Testing
@testable import vcdr_ios

@Suite("KeyboardChannel seam")
struct KeyboardChannelSeamTests {
    @Test("fake records publication command and heartbeat interactions")
    func fakeRecordsProtocolInteractions() {
        let fake = FakeKeyboardChannel()
        let channel: any KeyboardChannelProtocol = fake
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = KeyboardWireSnapshot(
            appSession: UUID(), seq: 1, run: nil, handledCommands: [], writtenAt: now
        )
        let command = KeyboardCommand(id: CommandID(), kind: .start, sentAt: now)

        channel.publish(snapshot)
        fake.enqueue(command)
        #expect(channel.readCommands() == [command])

        #expect(!channel.isAppLikelyAlive(now: now))
        channel.writeHeartbeat(alive: true, now: now.addingTimeInterval(-5))
        #expect(channel.isAppLikelyAlive(now: now))
        channel.writeHeartbeat(alive: true, now: now.addingTimeInterval(-30))
        #expect(!channel.isAppLikelyAlive(now: now))

        #expect(fake.interactions == [
            .publish(snapshot),
            .readCommands,
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
        let coordinator = RecordingFlowCoordinator(presence: SpyMicPresenceCard(), keyboardChannel: fake)

        coordinator.keyboardWire.publishLaunch()

        #expect(fake.published.count == 1)
        #expect(fake.published.first?.run == nil)
        #expect(fake.published.first?.handledCommands == [])
    }
}
