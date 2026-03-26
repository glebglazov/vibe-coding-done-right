import AppKit

extension CapturePanel {

    static let lineHeight: CGFloat = 20
    static let contentPadding: CGFloat = 24
    static let hintBarHeight: CGFloat = 30
    static let panelMinBaseHeight: CGFloat = 60
    static let errorBannerHeight: CGFloat = 28

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

        // Panel shows a single text: processed output or raw transcription
        let displayText = turn.output ?? turn.input
        let totalLines = CGFloat(displayText.components(separatedBy: .newlines).count)
        let contentHeight = totalLines * lineHeight + contentPadding
        let total = panelMinBaseHeight + contentHeight + hintBarHeight + errorHeight
        return min(total, maxPanelHeight())
    }

    static func panelOrigin(width: CGFloat, height: CGFloat) -> NSPoint? {
        panelOriginBelowMenuBar(width: width, height: height, offset: panelOffsetBelowMenuBar)
    }
}
