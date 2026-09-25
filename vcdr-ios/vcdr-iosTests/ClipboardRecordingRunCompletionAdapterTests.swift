import Foundation
import Testing
@testable import vcdr_ios

@MainActor
struct ClipboardRecordingRunCompletionAdapterTests {
    @Test("a success copies the final text")
    func successCopiesFinalText() async {
        let pasteboard = SpyPasteboard()
        let adapter = ClipboardRecordingRunCompletionAdapter(pasteboard: pasteboard)

        await adapter.complete(.success(RecordingRunSuccess(
            conversationID: UUID(),
            transcript: "hello world",
            processed: "Hello, world",
            finalText: "Hello, world.",
            captures: [],
            historyLabel: nil
        )))

        #expect(pasteboard.writes == ["Hello, world."])
    }

    @Test("an empty result, a cancellation and a failure leave the clipboard alone")
    func otherOutcomesCopyNothing() async {
        let pasteboard = SpyPasteboard()
        let adapter = ClipboardRecordingRunCompletionAdapter(pasteboard: pasteboard)

        await adapter.complete(.emptyResult)
        await adapter.complete(.cancellation)
        await adapter.complete(.processingFailure(RecordingRunFailure(message: "model failed")))

        #expect(pasteboard.writes.isEmpty)
    }
}

@MainActor
final class SpyPasteboard: PasteboardWriting {
    private(set) var writes: [String] = []

    func write(_ text: String) {
        writes.append(text)
    }
}
