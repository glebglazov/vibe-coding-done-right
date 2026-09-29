import AppKit
import Foundation
import Testing
@testable import vcdr_mac

@Suite("ClipboardMonitor", .serialized)
@MainActor
struct ClipboardMonitorTests {
    private static let captureTimeout: Duration = .seconds(2)
    private static let capturePollInterval: Duration = .milliseconds(50)
    private static let absenceWindow: Duration = .seconds(1)

    @Test("Captures same text again when pasteboard changeCount changes")
    func capturesSameTextOnNewPasteboardChange() async {
        let pasteboard = NSPasteboard(name: .init("vcdr.test.\(UUID().uuidString)"))
        let text = "same copied text \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let monitor = ClipboardMonitor(pasteboardName: pasteboard.name.rawValue)
        var captures: [String] = []
        await monitor.start(baselineChangeCount: pasteboard.changeCount) { capturedText in
            captures.append(capturedText)
        }

        writeStringToPasteboard(text, pasteboard: pasteboard)
        await waitForMatchingCaptureCount(1, text: text, captures: { captures })

        writeStringToPasteboard(text, pasteboard: pasteboard)
        await waitForMatchingCaptureCount(2, text: text, captures: { captures })

        await monitor.stop()
        #expect(captures.filter { $0 == text } == [text, text])
    }

    @Test("A stop that lands before its start keeps the monitor from capturing")
    func stopBeforeStartWins() async {
        let pasteboard = NSPasteboard(name: .init("vcdr.test.\(UUID().uuidString)"))
        let text = "copied after stop \(UUID().uuidString)"
        let monitor = ClipboardMonitor(pasteboardName: pasteboard.name.rawValue)
        var captures: [String] = []

        await monitor.stop()
        await monitor.start(baselineChangeCount: pasteboard.changeCount) { capturedText in
            captures.append(capturedText)
        }
        writeStringToPasteboard(text, pasteboard: pasteboard)
        try? await Task.sleep(for: Self.absenceWindow)

        #expect(captures.isEmpty)
    }

    @Test("A late stop from an earlier run leaves a later run monitoring")
    func staleStopLeavesLaterRunMonitoring() async {
        let pasteboard = NSPasteboard(name: .init("vcdr.test.\(UUID().uuidString)"))
        let text = "copied in later run \(UUID().uuidString)"
        let earlierRun = ClipboardMonitor(pasteboardName: pasteboard.name.rawValue)
        let laterRun = ClipboardMonitor(pasteboardName: pasteboard.name.rawValue)
        var captures: [String] = []

        await earlierRun.start(baselineChangeCount: pasteboard.changeCount) { _ in }
        await laterRun.start(baselineChangeCount: pasteboard.changeCount) { capturedText in
            captures.append(capturedText)
        }
        await earlierRun.stop()
        writeStringToPasteboard(text, pasteboard: pasteboard)
        await waitForMatchingCaptureCount(1, text: text, captures: { captures })

        #expect(captures == [text])
        await laterRun.stop()
    }

    @Test("A monitor released without a stop stops capturing")
    func releasedMonitorStopsCapturing() async {
        let pasteboard = NSPasteboard(name: .init("vcdr.test.\(UUID().uuidString)"))
        let text = "copied after release \(UUID().uuidString)"
        var monitor: ClipboardMonitor? = ClipboardMonitor(pasteboardName: pasteboard.name.rawValue)
        var captures: [String] = []

        await monitor?.start(baselineChangeCount: pasteboard.changeCount) { capturedText in
            captures.append(capturedText)
        }
        monitor = nil
        writeStringToPasteboard(text, pasteboard: pasteboard)
        try? await Task.sleep(for: Self.absenceWindow)

        #expect(captures.isEmpty)
    }

    private func writeStringToPasteboard(_ text: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
