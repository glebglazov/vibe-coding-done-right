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
