import ApplicationServices
import Foundation

/// The Accessibility grant, as the code that needs it sees it: whether the
/// process has it, and the app's one request for it.
///
/// Nothing asks at launch. The grant buys pasting and reading the text around the cursor —
/// hotkeys need none of it — so the ask belongs to the first paste that finds the
/// process untrusted, where the user can see what it is for.
///
/// It is spent once. A user who declines is still told, by the error every later
/// paste reports and by the standing notice on the Home tab; a dialog on every
/// dictation would only teach them to dismiss it unread.
final class AccessibilityGrant: @unchecked Sendable {

    /// The real grant: macOS's own trust check and its own dialog.
    static let system = AccessibilityGrant(
        isGranted: { AXIsProcessTrusted() },
        ask: showSystemDialog
    )

    private let isGrantedCheck: () -> Bool
    private let ask: () -> Void
    private let lock = NSLock()
    private var hasAsked = false

    init(isGranted: @escaping () -> Bool, ask: @escaping () -> Void) {
        self.isGrantedCheck = isGranted
        self.ask = ask
    }

    var isGranted: Bool { isGrantedCheck() }

    /// Asks on the first call, and does nothing on every call after it.
    func requestOnce() {
        lock.lock()
        let alreadyAsked = hasAsked
        hasAsked = true
        lock.unlock()

        guard !alreadyAsked else { return }
        ask()
    }

    private static func showSystemDialog() {
        // The dialog is the system's to present, so ask for it from the main thread.
        Task { @MainActor in
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
