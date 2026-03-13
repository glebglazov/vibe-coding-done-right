import AppKit
import SwiftUI

// MARK: - Custom Attributed String Keys

extension NSAttributedString.Key {
    /// Which InputSegment this text belongs to (Int index).
    static let segmentIndex = NSAttributedString.Key("vcdr.segmentIndex")
    /// Whether this region is a non-editable capture blockquote (Bool).
    static let isCapture = NSAttributedString.Key("vcdr.isCapture")
    /// Whether this region is a structural separator (newline between segments) that cannot be edited (Bool).
    static let isSeparator = NSAttributedString.Key("vcdr.isSeparator")
}

// MARK: - SegmentedTextView

struct SegmentedTextView: NSViewRepresentable {
    var segments: [InputSegment]
    var segmentsVersion: Int
    var isEditable: Bool
    var onSegmentsChanged: ([InputSegment]) -> Void
    var onActiveSegmentChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.rebuildAttributedString()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        // Only rebuild when segments change programmatically (version bump),
        // not when the user types (coordinator sets isUserEditing flag).
        guard !context.coordinator.isUserEditing else { return }
        context.coordinator.parent = self
        if context.coordinator.lastBuiltVersion != segmentsVersion {
            context.coordinator.rebuildAttributedString()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentedTextView
        weak var textView: NSTextView?
        var isUserEditing = false
        var lastBuiltVersion: Int = -1

        /// Previous cursor location, used to detect movement direction.
        var previousCursorLocation: Int = 0
        /// Guard flag to prevent infinite recursion when we programmatically adjust the selection.
        var isAdjustingSelection = false

        // MARK: - Constants

        private static let editableFontSize: CGFloat = 13
        private static let captureFontSize: CGFloat = 12
        private static let captureIndent: CGFloat = 12
        private static let separatorFontSize: CGFloat = 4

        init(parent: SegmentedTextView) {
            self.parent = parent
        }

        // MARK: - Build attributed string from segments

        func rebuildAttributedString() {
            guard let textView else { return }
            let cursor = textView.selectedRange()
            let attrStr = buildAttributedString(from: parent.segments)
            textView.textStorage?.setAttributedString(attrStr)
            // Restore cursor, clamped to valid range
            let maxLoc = attrStr.length
            let safeLoc = min(cursor.location, maxLoc)
            let safeLen = min(cursor.length, maxLoc - safeLoc)
            textView.setSelectedRange(NSRange(location: safeLoc, length: safeLen))
            lastBuiltVersion = parent.segmentsVersion
        }

        private func buildAttributedString(from segments: [InputSegment]) -> NSAttributedString {
            let result = NSMutableAttributedString()

            for (index, segment) in segments.enumerated() {
                // Editable text region
                let textContent = segment.text.isEmpty && segment.capture != nil ? "" : segment.text
                let editableAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: Self.editableFontSize),
                    .foregroundColor: NSColor.textColor,
                    .segmentIndex: index,
                    .isCapture: false,
                    .isSeparator: false
                ]
                result.append(NSAttributedString(string: textContent, attributes: editableAttrs))

                // Capture blockquote (non-editable)
                if let capture = segment.capture {
                    // Separator newline before capture
                    let separatorAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: Self.separatorFontSize),
                        .isSeparator: true,
                        .isCapture: false,
                        .segmentIndex: index
                    ]
                    result.append(NSAttributedString(string: "\n", attributes: separatorAttrs))

                    // Capture text
                    let captureParaStyle = NSMutableParagraphStyle()
                    captureParaStyle.headIndent = Self.captureIndent
                    captureParaStyle.firstLineHeadIndent = Self.captureIndent

                    let captureAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: Self.captureFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .backgroundColor: NSColor.quaternaryLabelColor,
                        .paragraphStyle: captureParaStyle,
                        .segmentIndex: index,
                        .isCapture: true,
                        .isSeparator: false
                    ]
                    result.append(NSAttributedString(string: capture.text, attributes: captureAttrs))
                }

                // Separator newline between segments (not after the last one)
                if index < segments.count - 1 {
                    let separatorAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: Self.separatorFontSize),
                        .isSeparator: true,
                        .isCapture: false,
                        .segmentIndex: index
                    ]
                    result.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
                }
            }

            return result
        }

        // MARK: - Protect capture/separator regions from edits

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString text: String?) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let length = storage.length

            // Allow changes at the end of the document (appending)
            if range.location >= length && range.length == 0 { return true }

            // Check every character in the affected range
            let effectiveEnd = min(range.location + range.length, length)
            if range.location < length {
                let checkRange = NSRange(location: range.location, length: max(1, effectiveEnd - range.location))
                var blocked = false
                storage.enumerateAttributes(in: checkRange, options: []) { attrs, _, stop in
                    if attrs[.isCapture] as? Bool == true ||
                       attrs[.isSeparator] as? Bool == true {
                        blocked = true
                        stop.pointee = true
                    }
                }
                if blocked { return false }
            }

            // Block if the replacement would merge across segments
            if range.length > 0, range.location < length {
                let startSeg = storage.attribute(.segmentIndex, at: range.location,
                                                 effectiveRange: nil) as? Int
                let endLoc = min(range.location + range.length - 1, length - 1)
                let endSeg = storage.attribute(.segmentIndex, at: endLoc,
                                              effectiveRange: nil) as? Int
                if startSeg != endSeg { return false }
            }
            return true
        }

        // MARK: - Sync text changes back to segment model

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            isUserEditing = true
            defer { isUserEditing = false }

            // Re-extract editable text for each segment from the attributed string
            var updatedSegments = parent.segments
            for segIdx in updatedSegments.indices {
                var segText = ""
                storage.enumerateAttributes(
                    in: NSRange(location: 0, length: storage.length),
                    options: []
                ) { attrs, range, _ in
                    if attrs[.segmentIndex] as? Int == segIdx,
                       attrs[.isCapture] as? Bool != true,
                       attrs[.isSeparator] as? Bool != true {
                        segText += (storage.string as NSString).substring(with: range)
                    }
                }
                updatedSegments[segIdx] = InputSegment(
                    id: updatedSegments[segIdx].id,
                    text: segText,
                    capture: updatedSegments[segIdx].capture
                )
            }
            parent.onSegmentsChanged(updatedSegments)
        }

        // MARK: - Cursor skip-over for non-editable regions

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            guard !isAdjustingSelection else { return }

            let sel = textView.selectedRange()
            let loc = sel.location
            guard loc < storage.length else {
                previousCursorLocation = loc
                return
            }

            let isCaptureRegion = storage.attribute(.isCapture, at: loc, effectiveRange: nil) as? Bool ?? false
            let isSeparatorRegion = storage.attribute(.isSeparator, at: loc, effectiveRange: nil) as? Bool ?? false

            if isCaptureRegion || isSeparatorRegion {
                // Cursor landed in a non-editable region — bounce it to the nearest editable boundary.
                let movingBackward = loc < previousCursorLocation
                let newLoc = findNearestEditablePosition(from: loc, movingBackward: movingBackward, in: storage)
                isAdjustingSelection = true
                textView.setSelectedRange(NSRange(location: newLoc, length: 0))
                isAdjustingSelection = false
                previousCursorLocation = newLoc
            } else {
                previousCursorLocation = loc
            }

            // Update active segment from final cursor position
            let finalLoc = textView.selectedRange().location
            if finalLoc < storage.length,
               let segIdx = storage.attribute(.segmentIndex, at: finalLoc, effectiveRange: nil) as? Int {
                parent.onActiveSegmentChanged(segIdx)
            }
        }

        /// Scans the attributed string from `position` in the given direction
        /// to find the first character that is editable (not capture, not separator).
        private func findNearestEditablePosition(from position: Int, movingBackward: Bool, in storage: NSAttributedString) -> Int {
            let length = storage.length
            if movingBackward {
                var pos = position - 1
                while pos >= 0 {
                    let isCap = storage.attribute(.isCapture, at: pos, effectiveRange: nil) as? Bool ?? false
                    let isSep = storage.attribute(.isSeparator, at: pos, effectiveRange: nil) as? Bool ?? false
                    if !isCap && !isSep {
                        return pos + 1 // Place cursor after the last editable character
                    }
                    pos -= 1
                }
                return 0
            } else {
                var pos = position + 1
                while pos < length {
                    let isCap = storage.attribute(.isCapture, at: pos, effectiveRange: nil) as? Bool ?? false
                    let isSep = storage.attribute(.isSeparator, at: pos, effectiveRange: nil) as? Bool ?? false
                    if !isCap && !isSep {
                        return pos
                    }
                    pos += 1
                }
                return length
            }
        }
    }
}
