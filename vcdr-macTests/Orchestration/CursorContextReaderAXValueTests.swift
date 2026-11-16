import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import vcdr_mac

@Suite("CursorContextReader — cfRange(fromAXAttributeValue:)")
struct CursorContextReaderAXValueTests {

    @Test("Non-AXValue AnyObject returns nil instead of trapping")
    func nonAXValueReturnsNil() {
        let string: AnyObject = "hello" as NSString
        #expect(CursorContextReader.cfRange(fromAXAttributeValue: string) == nil)

        let number: AnyObject = NSNumber(value: 42)
        #expect(CursorContextReader.cfRange(fromAXAttributeValue: number) == nil)

        let null: AnyObject = NSNull()
        #expect(CursorContextReader.cfRange(fromAXAttributeValue: null) == nil)
    }

    @Test("AXValue carrying a cfRange is decoded correctly")
    func validCFRangeAXValue() throws {
        var source = CFRange(location: 5, length: 3)
        let axValue = try #require(AXValueCreate(.cfRange, &source))

        let decoded = try #require(CursorContextReader.cfRange(fromAXAttributeValue: axValue))
        #expect(decoded.location == 5)
        #expect(decoded.length == 3)
    }

    @Test("AXValue of the wrong type returns nil")
    func wrongTypeAXValueReturnsNil() throws {
        var point = CGPoint(x: 10, y: 20)
        let axValue = try #require(AXValueCreate(.cgPoint, &point))

        #expect(CursorContextReader.cfRange(fromAXAttributeValue: axValue) == nil)
    }
}

@Suite("CursorContextReader — reads only")
struct CursorContextReaderReadsOnlyTests {
    /// Selection Capture once fell back to pressing Copy and to a Command-C
    /// Synthetic Keystroke, and then waited this long for the clipboard to
    /// change. A read that posts no keystroke has nothing to wait for.
    private static let clipboardWaitAfterKeystroke: Duration = .milliseconds(300)

    @Test("Reading the Cursor Context posts no Synthetic Keystroke and leaves the clipboard alone")
    func readPostsNoKeystroke() {
        let changeCount = NSPasteboard.general.changeCount

        let elapsed = ContinuousClock().measure {
            _ = CursorContextReader().read(bundleIdentifier: Bundle.main.bundleIdentifier, pid: getpid())
        }

        #expect(NSPasteboard.general.changeCount == changeCount)
        #expect(elapsed < Self.clipboardWaitAfterKeystroke)
    }
}
