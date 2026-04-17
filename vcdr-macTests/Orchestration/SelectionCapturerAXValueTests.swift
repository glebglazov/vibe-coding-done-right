import ApplicationServices
import Foundation
import Testing
@testable import vcdr_mac

@Suite("SelectionCapturer — cfRange(fromAXAttributeValue:)")
struct SelectionCapturerAXValueTests {

    @Test("Non-AXValue AnyObject returns nil instead of trapping")
    func nonAXValueReturnsNil() {
        let string: AnyObject = "hello" as NSString
        #expect(SelectionCapturer.cfRange(fromAXAttributeValue: string) == nil)

        let number: AnyObject = NSNumber(value: 42)
        #expect(SelectionCapturer.cfRange(fromAXAttributeValue: number) == nil)

        let null: AnyObject = NSNull()
        #expect(SelectionCapturer.cfRange(fromAXAttributeValue: null) == nil)
    }

    @Test("AXValue carrying a cfRange is decoded correctly")
    func validCFRangeAXValue() throws {
        var source = CFRange(location: 5, length: 3)
        let axValue = try #require(AXValueCreate(.cfRange, &source))

        let decoded = try #require(SelectionCapturer.cfRange(fromAXAttributeValue: axValue))
        #expect(decoded.location == 5)
        #expect(decoded.length == 3)
    }

    @Test("AXValue of the wrong type returns nil")
    func wrongTypeAXValueReturnsNil() throws {
        var point = CGPoint(x: 10, y: 20)
        let axValue = try #require(AXValueCreate(.cgPoint, &point))

        #expect(SelectionCapturer.cfRange(fromAXAttributeValue: axValue) == nil)
    }
}
