import AppKit
import SwiftUI

/// Lightweight NSTextView wrapper for editing a single segment's text.
/// Handles only plain text — no attributed
/// string regions, no cursor bouncing, no separator fonts.
///
/// Supports cross-editor arrow key navigation: when the cursor is on the
/// first/last line and the user presses arrow up/down, the `onMoveUp`/`onMoveDown`
/// callbacks fire so the parent can shift focus to the adjacent editor.
struct SegmentEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// Bump to request focus. The editor becomes first responder when this changes.
    var focusTrigger: Int = 0
    /// When focus is requested, place cursor at end (true) or start (false).
    var focusCursorAtEnd: Bool = false
    var onFocus: () -> Void
    /// Called when arrow-up is pressed while the cursor is on the first line.
    var onMoveUp: (() -> Void)?
    /// Called when arrow-down is pressed while the cursor is on the last line.
    var onMoveDown: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Constants

    private static let fontSize: CGFloat = 13
    private static let textContainerInset = NSSize(width: 8, height: 4)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: Self.fontSize)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = Self.textContainerInset
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Keep coordinator's parent in sync so its @Binding and closures
        // always point at the current SegmentEditor struct, not a stale copy.
        context.coordinator.parent = self
        textView.isEditable = isEditable
        // Only update from external changes (coordinator appends, setSegments, etc.)
        // During user typing, textDidChange already synced parent.text = textView.string,
        // so they're equal and this guard prevents clobbering the cursor.
        if textView.string != text {
            let cursor = textView.selectedRange()
            textView.string = text
            let maxLoc = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(cursor.location, maxLoc), length: 0))
        }
        // Handle focus requests from parent (arrow key navigation between editors).
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            let length = (textView.string as NSString).length
            let loc = focusCursorAtEnd ? length : 0
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            nsView.window?.makeFirstResponder(textView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentEditor
        var lastFocusTrigger: Int = 0

        init(_ parent: SegmentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.onFocus()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if isOnFirstLine(textView), let onMoveUp = parent.onMoveUp {
                    onMoveUp()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if isOnLastLine(textView), let onMoveDown = parent.onMoveDown {
                    onMoveDown()
                    return true
                }
            }
            return false
        }

        // MARK: - Cursor Boundary Detection

        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            let cursorLoc = textView.selectedRange().location
            let text = textView.string as NSString
            let preceding = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cursorLoc))
            return preceding.location == NSNotFound
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            let cursorLoc = textView.selectedRange().location
            let text = textView.string as NSString
            let remaining = text.range(of: "\n", range: NSRange(location: cursorLoc, length: text.length - cursorLoc))
            return remaining.location == NSNotFound
        }
    }
}
