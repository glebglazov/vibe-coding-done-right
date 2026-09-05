import Foundation
import Testing
@testable import vcdr_mac

/// Accessibility is what a paste needs and no hotkey does, so this is where the
/// app asks for it. The grant is injected rather than read from the process: a
/// developer machine that has granted the test host would otherwise run the real
/// paste, simulating Cmd+V into whatever is frontmost.
@Suite("PasteAction — Accessibility prompt")
struct PasteActionAccessibilityTests {

    /// Counts asks from whichever thread `execute` happens to be on.
    private final class AskCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test("A paste without the Accessibility grant asks for it once, and reports the failure every time")
    func promptsOnceAndKeepsReportingTheMissingGrant() async {
        let asks = AskCounter()
        let action = PasteAction(
            accessibilityGrant: AccessibilityGrant(isGranted: { false }, ask: { asks.record() })
        )

        for _ in 0..<3 {
            await #expect(throws: ActionError.self) {
                try await action.execute(text: "dictated text")
            }
        }

        #expect(asks.value == 1)
    }
}
