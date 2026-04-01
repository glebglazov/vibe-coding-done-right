import AppKit

extension CapturePanel {

    static let contentPadding: CGFloat = 24
    static let hintBarHeight: CGFloat = 30
    static let panelMinBaseHeight: CGFloat = 60
    static let errorBannerHeight: CGFloat = 28
    /// Usable text width inside the panel (panel width minus horizontal padding)
    private static let textAreaWidth: CGFloat = 480 - (CaptureView.textPadding * 2)

    static func maxPanelHeight() -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return visibleHeight * panelMaxHeightFraction
    }

    static func calculateHeight(for turn: DisplayedTurn?, hasError: Bool = false) -> CGFloat {
        let errorHeight: CGFloat = hasError ? errorBannerHeight : 0

        guard let turn else {
            let total = panelMinBaseHeight + hintBarHeight + errorHeight
            return min(total, maxPanelHeight())
        }

        let displayText = turn.output ?? turn.input
        let textHeight = measureTextHeight(for: displayText)
        let contentHeight = textHeight + contentPadding
        let total = panelMinBaseHeight + contentHeight + hintBarHeight + errorHeight
        return min(total, maxPanelHeight())
    }

    /// Measures the actual rendered height of the text using the same monospaced
    /// body font that CaptureView uses, accounting for wrapping at the panel width.
    private static func measureTextHeight(for text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: textAreaWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(boundingRect.height)
    }

    static func panelOrigin(width: CGFloat, height: CGFloat) -> NSPoint? {
        panelOriginBelowMenuBar(width: width, height: height, offset: panelOffsetBelowMenuBar)
    }
}
