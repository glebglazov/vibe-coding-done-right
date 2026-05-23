import AppKit
import Foundation
import Testing
@testable import vcdr_mac

@Suite("ClipboardMonitor", .serialized)
@MainActor
struct ClipboardMonitorTests {
    private static let captureTimeout: Duration = .seconds(2)
    private static let capturePollInterval: Duration = .milliseconds(50)

    @Test("Captures same text again when pasteboard changeCount changes")
    func capturesSameTextOnNewPasteboardChange() async {
        let snapshot = ClipboardHelper.saveContents()
        defer {
            if snapshot.isEmpty {
                NSPasteboard.general.clearContents()
            } else {
                ClipboardHelper.restoreContents(snapshot)
            }
        }

        let pasteboard = NSPasteboard.general
        let text = "same copied text \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let monitor = ClipboardMonitor()
        var captures: [String] = []
        await monitor.start(baselineChangeCount: pasteboard.changeCount) { capturedText in
            captures.append(capturedText)
        }

        writeStringToPasteboard(text)
        await waitForMatchingCaptureCount(1, text: text, captures: { captures })

        writeStringToPasteboard(text)
        await waitForMatchingCaptureCount(2, text: text, captures: { captures })

        _ = await monitor.stop()
        #expect(captures.filter { $0 == text } == [text, text])
    }

    private func writeStringToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func waitForMatchingCaptureCount(
        _ expectedCount: Int,
        text: String,
        captures: @MainActor () -> [String]
    ) async {
        let deadline = ContinuousClock.now + Self.captureTimeout
        while captures().filter({ $0 == text }).count < expectedCount, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.capturePollInterval)
        }
    }
}
