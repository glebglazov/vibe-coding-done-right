import AppKit
import SwiftUI

/// Lightweight NSTextView wrapper for editing a single segment's text.
struct SegmentEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// Called when the editor gains focus.
    var onFocus: (() -> Void)?
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
        textView.isEditable = isEditable
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        context.coordinator.reportHeight(textView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentEditor
        private var lastReportedHeight: CGFloat = 0
        private static let heightChangeThreshold: CGFloat = 1

        init(_ parent: SegmentEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(textView)
        }

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
            parent.onFocus?()
        }

        /// Suppress Cocoa text-editing keybindings that conflict with destination hotkeys.
        private static let suppressedSelectors: Set<Selector> = [
            #selector(NSResponder.transpose(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        ]

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if Self.suppressedSelectors.contains(commandSelector) {
                return true
            }
            return false
        }
    }
}
