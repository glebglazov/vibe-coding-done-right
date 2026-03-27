import SwiftUI
import AppKit

/// A monospaced text editor for shell commands with smart quotes and
/// automatic text substitution disabled. Highlights `$VARIABLE` references:
/// green for defined variables, red for undefined. Auto-sizes to fit content.
struct CommandTextEditor: NSViewRepresentable {
    @Binding var text: String
    var definedVariableNames: Set<String> = []

    // MARK: - Constants

    private static let minHeight: CGFloat = 40
    private static let maxHeight: CGFloat = 300
    /// Vertical padding inside the scroll view (border + text container inset).
    private static let verticalPadding: CGFloat = 10

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.font = Coordinator.monoFont
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // Enable rich text so attributed string coloring works
        textView.isRichText = true
        textView.isAutomaticTextCompletionEnabled = false

        // Watch for layout changes to recalculate height
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        context.coordinator.scrollView = scrollView
        context.coordinator.applyHighlighting(textView)
        context.coordinator.recalculateHeight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.applyHighlighting(textView)
        context.coordinator.recalculateHeight(textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? scrollView.frame.width
        let height = max(Self.minHeight, min(context.coordinator.contentHeight + Self.verticalPadding, Self.maxHeight))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandTextEditor
        weak var scrollView: NSScrollView?
        var contentHeight: CGFloat = 0

        // MARK: - Constants

        static let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        private static let variablePattern: NSRegularExpression = {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: "\\$([A-Za-z_][A-Za-z0-9_]*)", options: [])
        }()
        private static let builtInVariableNames: Set<String> = ["VCDR_TEXT", "VCDR_DICTATION"]
        private static let builtInVariablePrefix = "VCDR_PARAM_"
        private static let definedVariableColor = NSColor.systemGreen
        private static let undefinedVariableColor = NSColor.systemRed

        init(_ parent: CommandTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(textView)
            recalculateHeight(textView)
        }

        @objc func frameDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let newHeight = usedRect.height
            if abs(newHeight - contentHeight) > 1 {
                contentHeight = newHeight
                scrollView?.invalidateIntrinsicContentSize()
            }
        }

        func applyHighlighting(_ textView: NSTextView) {
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard let textStorage = textView.textStorage else { return }

            textStorage.beginEditing()

            // Reset to default appearance
            textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            textStorage.addAttribute(.font, value: Self.monoFont, range: fullRange)

            // Color variable references
            let matches = Self.variablePattern.matches(in: text, range: fullRange)
            for match in matches {
                let varNameRange = match.range(at: 1)
                let varName = (text as NSString).substring(with: varNameRange)
                let isDefined = Self.builtInVariableNames.contains(varName)
                    || varName.hasPrefix(Self.builtInVariablePrefix)
                    || parent.definedVariableNames.contains(varName)

                let color = isDefined ? Self.definedVariableColor : Self.undefinedVariableColor
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }

            textStorage.endEditing()
        }
    }
}
