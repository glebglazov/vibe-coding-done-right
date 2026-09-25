import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Pins the wire state the widget decodes and the one button each face offers.
struct MicPresenceCardStateTests {
    private static let everyFace: [MicPresenceCardState] = [
        .ready,
        .arming,
        .capturing(since: Date(timeIntervalSince1970: 1_000)),
        .finalizing,
        .concluded(.copied),
        .concluded(.noSpeech),
        .concluded(.failed),
    ]

    @Test("every face survives the trip to the widget", arguments: everyFace)
    func roundTrip(face: MicPresenceCardState) throws {
        let data = try JSONEncoder().encode(face)
        #expect(try JSONDecoder().decode(MicPresenceCardState.self, from: data) == face)
    }

    @Test("Arming offers Cancel, Capturing offers Stop, and no other face has a button")
    func stopControl() {
        #expect(MicPresenceCardState.arming.stopControl == .cancel)
        #expect(MicPresenceCardState.capturing(since: .now).stopControl == .stop)
        #expect(MicPresenceCardState.ready.stopControl == nil)
        #expect(MicPresenceCardState.finalizing.stopControl == nil)
        #expect(MicPresenceCardState.concluded(.copied).stopControl == nil)
    }
}
