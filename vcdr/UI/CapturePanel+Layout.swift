import AppKit

extension CapturePanel {

    static let lineHeight: CGFloat = 20
    static let labelLineHeight: CGFloat = 18
    static let conversationPadding: CGFloat = 24
    static let hintBarHeight: CGFloat = 30
    static let panelMinBaseHeight: CGFloat = 60
    static let errorBannerHeight: CGFloat = 28
    /// Scaling factor for capture text line height (slightly tighter than normal text)
    private static let captureLineHeightScale: CGFloat = 0.9

    static func maxPanelHeight() -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return visibleHeight * panelMaxHeightFraction
    }

    static func calculateHeight(for turn: ConversationTurn?, hasError: Bool = false) -> CGFloat {
        let errorHeight: CGFloat = hasError ? errorBannerHeight : 0

        guard let turn else {
            let total = panelMinBaseHeight + hintBarHeight + errorHeight
            return min(total, maxPanelHeight())
        }

        // Single displayed turn height
        var totalLines: CGFloat = 0
        totalLines += labelLineHeight / lineHeight  // "You:" label
        totalLines += CGFloat(turn.input.components(separatedBy: .newlines).count)
        if let output = turn.output {
            totalLines += labelLineHeight / lineHeight  // "Result:" label
            totalLines += CGFloat(output.components(separatedBy: .newlines).count)
        }

        for capture in turn.captures {
            totalLines += labelLineHeight / lineHeight
            totalLines += CGFloat(capture.text.components(separatedBy: .newlines).count) * captureLineHeightScale
        }

        let conversationHeight = totalLines * lineHeight + conversationPadding
        let total = panelMinBaseHeight + conversationHeight + hintBarHeight + errorHeight
        return min(total, maxPanelHeight())
    }

    static func panelOrigin(width: CGFloat, height: CGFloat) -> NSPoint? {
        panelOriginBelowMenuBar(width: width, height: height, offset: panelOffsetBelowMenuBar)
    }
}
