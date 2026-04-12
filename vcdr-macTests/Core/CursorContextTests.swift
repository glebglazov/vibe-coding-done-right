import Foundation
import Testing
@testable import vcdr_mac

@Suite("CursorContext Tests")
struct CursorContextTests {

    @Test("CursorContext conforms to required protocols")
    func protocolConformance() {
        // CursorContext must be Sendable for concurrent use
        let context = CursorContext(beforeText: "hello", afterText: "world", sourceBundleID: "com.test.app")

        // Codable - can be encoded/decoded
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        do {
            let data = try encoder.encode(context)
            let decoded = try decoder.decode(CursorContext.self, from: data)

            #expect(decoded.beforeText == context.beforeText)
            #expect(decoded.afterText == context.afterText)
            #expect(decoded.sourceBundleID == context.sourceBundleID)
        } catch {
            Issue.record("Encoding/decoding failed: \(error)")
        }
    }

    @Test("CursorContext equality")
    func equality() {
        let context1 = CursorContext(beforeText: "hello", afterText: "world", sourceBundleID: "com.test.app")
        let context2 = CursorContext(beforeText: "hello", afterText: "world", sourceBundleID: "com.test.app")
        let context3 = CursorContext(beforeText: "different", afterText: "world", sourceBundleID: "com.test.app")

        #expect(context1 == context2)
        #expect(context1 != context3)
    }

    @Test("CursorContext handles nil values")
    func nilValues() {
        let context = CursorContext(beforeText: nil, afterText: nil, sourceBundleID: nil)

        #expect(context.beforeText == nil)
        #expect(context.afterText == nil)
        #expect(context.sourceBundleID == nil)
    }

    @Test("CursorContext stores sourceBundleID for staleness checks")
    func sourceBundleIDForStaleness() {
        let bundleID = "com.apple.TextEdit"
        let context = CursorContext(beforeText: "text", afterText: nil, sourceBundleID: bundleID)

        #expect(context.sourceBundleID == bundleID)
    }
}

@Suite("SelectionCapturer CaptureResult Tests")
struct CaptureResultTests {

    @Test("CaptureResult stores selected text and cursor context")
    func captureResultStorage() {
        let context = CursorContext(beforeText: "before", afterText: "after", sourceBundleID: "com.test.app")
        let result = SelectionCapturer.CaptureResult(selectedText: "selected", cursorContext: context)

        #expect(result.selectedText == "selected")
        #expect(result.cursorContext?.beforeText == "before")
        #expect(result.cursorContext?.afterText == "after")
    }

    @Test("CaptureResult handles nil values")
    func captureResultNilValues() {
        let result = SelectionCapturer.CaptureResult(selectedText: nil, cursorContext: nil)

        #expect(result.selectedText == nil)
        #expect(result.cursorContext == nil)
    }

    @Test("CaptureResult equality")
    func captureResultEquality() {
        let context1 = CursorContext(beforeText: "before", afterText: "after", sourceBundleID: "com.test.app")
        let context2 = CursorContext(beforeText: "different", afterText: "after", sourceBundleID: "com.test.app")

        let result1 = SelectionCapturer.CaptureResult(selectedText: "selected", cursorContext: context1)
        let result2 = SelectionCapturer.CaptureResult(selectedText: "selected", cursorContext: context1)
        let result3 = SelectionCapturer.CaptureResult(selectedText: "selected", cursorContext: context2)
        let result4 = SelectionCapturer.CaptureResult(selectedText: "different", cursorContext: context1)

        #expect(result1 == result2)
        #expect(result1 != result3)
        #expect(result1 != result4)
    }

    @Test("CaptureResult is Sendable")
    func captureResultSendable() async {
        let context = CursorContext(beforeText: "before", afterText: "after", sourceBundleID: "com.test.app")
        let result = SelectionCapturer.CaptureResult(selectedText: "selected", cursorContext: context)

        // Verify Sendable by passing across isolation boundary
        let task = Task {
            return result
        }

        let received = await task.value
        #expect(received == result)
    }
}
