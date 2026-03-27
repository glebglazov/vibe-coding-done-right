import SwiftUI
import AppKit

/// A monospaced text editor for shell commands with smart quotes and
/// automatic text substitution disabled. Highlights `$VARIABLE` references:
/// green for defined variables, red for undefined.
struct CommandTextEditor: NSViewRepresentable {
    @Binding var text: String
    var definedVariableNames: Set<String> = []

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

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        context.coordinator.applyHighlighting(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.applyHighlighting(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandTextEditor

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
