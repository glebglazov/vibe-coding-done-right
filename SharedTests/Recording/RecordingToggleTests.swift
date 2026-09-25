import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

struct RecordingToggleTests {
    private static let capturing = RecordingRunPhase.capturing(since: Date(timeIntervalSince1970: 0))

    @Test("a toggle starts with no run, stops Arming and Capturing, and ignores a cancel or Finalizing in flight")
    func toggleTable() {
        #expect(RecordingToggle.command(for: nil) == .start)
        #expect(RecordingToggle.command(for: .arming) == .stop)
        #expect(RecordingToggle.command(for: Self.capturing) == .stop)
        #expect(RecordingToggle.command(for: .cancellingArming) == .ignore)
        #expect(RecordingToggle.command(for: .finalizing) == .ignore)
    }

    @Test("a stop never starts a run and never touches a Finalizing run")
    func stopTable() {
        #expect(RecordingToggle.stopCommand(for: nil) == .ignore)
        #expect(RecordingToggle.stopCommand(for: .arming) == .stop)
        #expect(RecordingToggle.stopCommand(for: Self.capturing) == .stop)
        #expect(RecordingToggle.stopCommand(for: .cancellingArming) == .ignore)
        #expect(RecordingToggle.stopCommand(for: .finalizing) == .ignore)
    }
}
