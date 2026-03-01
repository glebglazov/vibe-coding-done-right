import Foundation
import Testing
@testable import vcdr

// MARK: - fullCapture

@Suite("TranscriptionRecord.fullCapture")
struct TranscriptionRecordFullCaptureTests {

    @Test("Returns text only when no captured selection")
    func textOnly() {
        let record = TranscriptionRecord(text: "hello world", modelName: "Test", recordingDuration: 1.0)
        #expect(record.fullCapture == "hello world")
    }

    @Test("Joins text and captured selection with double newline")
    func textWithSelection() {
        let record = TranscriptionRecord(
            text: "rewrite this",
            modelName: "Test",
            recordingDuration: 1.0,
            capturedSelection: "selected text"
        )
        #expect(record.fullCapture == "rewrite this\n\nselected text")
    }

    @Test("Handles empty text with selection")
    func emptyTextWithSelection() {
        let record = TranscriptionRecord(
            text: "",
            modelName: "Test",
            recordingDuration: 0,
            capturedSelection: "selection"
        )
        #expect(record.fullCapture == "\n\nselection")
    }
}

// MARK: - formattedDuration

@Suite("TranscriptionRecord.formattedDuration")
struct TranscriptionRecordFormattedDurationTests {

    @Test(
        "Formats seconds as M:SS",
        arguments: [
            (0.0, "0:00"),
            (1.0, "0:01"),
            (3.0, "0:03"),
            (9.5, "0:10"),     // rounds 9.5 → 10
            (59.0, "0:59"),
            (60.0, "1:00"),
            (75.0, "1:15"),
            (125.0, "2:05"),
            (600.0, "10:00"),
        ]
    )
    func formatting(duration: TimeInterval, expected: String) {
        let record = TranscriptionRecord(text: "", modelName: "Test", recordingDuration: duration)
        #expect(record.formattedDuration == expected)
    }

    @Test("Rounds fractional seconds correctly")
    func rounding() {
        let roundDown = TranscriptionRecord(text: "", modelName: "Test", recordingDuration: 3.4)
        #expect(roundDown.formattedDuration == "0:03")

        let roundUp = TranscriptionRecord(text: "", modelName: "Test", recordingDuration: 3.5)
        #expect(roundUp.formattedDuration == "0:04")
    }
}

// MARK: - Init & Codable

@Suite("TranscriptionRecord initialization and Codable")
struct TranscriptionRecordInitTests {

    @Test("Each init generates a unique ID")
    func uniqueIDs() {
        let a = TranscriptionRecord(text: "a", modelName: "Test", recordingDuration: 1.0)
        let b = TranscriptionRecord(text: "b", modelName: "Test", recordingDuration: 1.0)
        #expect(a.id != b.id)
    }

    @Test("Optional fields default to nil")
    func optionalDefaults() {
        let record = TranscriptionRecord(text: "hello", modelName: "Test", recordingDuration: 1.0)
        #expect(record.processedText == nil)
        #expect(record.actionResult == nil)
        #expect(record.capturedSelection == nil)
    }

    @Test("Round-trips through encode/decode preserving all fields")
    func codableRoundTrip() throws {
        let original = TranscriptionRecord(
            text: "hello",
            processedText: "Hello.",
            modelName: "Parakeet",
            recordingDuration: 3.7,
            actionResult: "output",
            capturedSelection: "selected"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionRecord.self, from: data)
        #expect(decoded == original)
    }
}
