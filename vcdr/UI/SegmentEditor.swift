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
    /// Cursor position to restore when the view is first created (e.g., after expand from pill).
    /// If nil, cursor defaults to position 0.
    var initialCursorPosition: Int? = nil
    /// Called when the editor gains focus or the cursor moves. Parameter is the cursor offset.
    var onFocus: (_ cursorPosition: Int) -> Void
    /// Called when arrow-up is pressed while the cursor is on the first line.
    var onMoveUp: (() -> Void)?
    /// Called when arrow-down is pressed while the cursor is on the last line.
    var onMoveDown: (() -> Void)?
    /// Called when the editor's content height changes (including soft wraps).
    var onHeightChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Constants

    private static let fontSize: CGFloat = 13
    private static let textContainerInset = NSSize(width: 8, height: 4)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
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
        if let pos = initialCursorPosition {
            let maxLoc = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(pos, maxLoc), length: 0))
        }
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
            textView.string = text
            let length = (text as NSString).length
            // Use saved cursor position if available (e.g., after dictation insertion),
            // otherwise place cursor at end (e.g., setSegments full replacement).
            if let pos = initialCursorPosition {
                textView.setSelectedRange(NSRange(location: min(pos, length), length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: length, length: 0))
            }
        }
        // Handle focus requests from parent (arrow key navigation between editors).
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            let length = (textView.string as NSString).length
            let loc = focusCursorAtEnd ? length : 0
            textView.setSelectedRange(NSRange(location: loc, length: 0))
            nsView.window?.makeFirstResponder(textView)
        }
        // Report height on every update to catch layout changes (initial layout,
        // external text changes, width changes). The coordinator deduplicates
        // by comparing against lastReportedHeight.
        context.coordinator.reportHeight(textView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentEditor
        var lastFocusTrigger: Int = 0
        /// Last height reported via onHeightChange, used to deduplicate callbacks
        /// and prevent infinite SwiftUI update loops.
        private var lastReportedHeight: CGFloat = 0
        private static let heightChangeThreshold: CGFloat = 1

        init(_ parent: SegmentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(textView)
        }

        /// Computes the actual content height from the layout manager (including
        /// soft wraps) and notifies the parent if it changed.
        func reportHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2
            if abs(newHeight - lastReportedHeight) > Self.heightChangeThreshold {
                lastReportedHeight = newHeight
                parent.onHeightChange?(newHeight)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onFocus(textView.selectedRange().location)
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
