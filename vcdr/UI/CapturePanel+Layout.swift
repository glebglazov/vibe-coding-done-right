import AppKit

extension CapturePanel {

    static let lineHeight: CGFloat = 20
    static let labelLineHeight: CGFloat = 18
    static let turnDividerHeight: CGFloat = 10
    static let conversationPadding: CGFloat = 24
    static let hintBarHeight: CGFloat = 30
    static let panelMinBaseHeight: CGFloat = 60
    static let segmentSectionMinHeight: CGFloat = 28

    static func maxPanelHeight() -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return visibleHeight * panelMaxHeightFraction
    }

    static func calculateHeight(for turns: [ConversationTurn], segments: [InputSegment] = [InputSegment()], segmentHeights: [UUID: CGFloat] = [:]) -> CGFloat {
        var segmentContentHeight: CGFloat = 0
        for segment in segments {
            // Use layout-reported height if available (accounts for soft wraps),
            // otherwise fall back to newline counting.
            if let reportedHeight = segmentHeights[segment.id], reportedHeight > 0 {
                segmentContentHeight += reportedHeight
            } else {
                let textLines = max(1, CGFloat(segment.text.components(separatedBy: .newlines).count))
                segmentContentHeight += textLines * lineHeight
            }

            if let capture = segment.capture {
                let captureLines = CGFloat(capture.text.components(separatedBy: .newlines).count)
                segmentContentHeight += captureLines * lineHeight * 0.9
                segmentContentHeight += 8 // separator spacing
            }
        }
        let extraHeight = max(segmentSectionMinHeight, segmentContentHeight)

        guard !turns.isEmpty else {
            let total = panelMinBaseHeight + extraHeight + hintBarHeight
            return min(total, maxPanelHeight())
        }

        var totalLines: CGFloat = 0
        for (index, turn) in turns.enumerated() {
            totalLines += labelLineHeight / lineHeight
            totalLines += CGFloat(turn.input.components(separatedBy: .newlines).count)
            totalLines += labelLineHeight / lineHeight
            totalLines += CGFloat(turn.output.components(separatedBy: .newlines).count)

            for capture in turn.captures {
                totalLines += labelLineHeight / lineHeight
                totalLines += CGFloat(capture.text.components(separatedBy: .newlines).count) * 0.9
            }

            if index < turns.count - 1 {
                totalLines += turnDividerHeight / lineHeight
            }
        }

        let conversationHeight = totalLines * lineHeight + conversationPadding
        let total = panelMinBaseHeight + conversationHeight + extraHeight + hintBarHeight
        return min(total, maxPanelHeight())
    }

    static func panelOrigin(width: CGFloat, height: CGFloat) -> NSPoint? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - menuBarHeight - height - panelOffsetBelowMenuBar
        return NSPoint(x: x, y: y)
    }
}
