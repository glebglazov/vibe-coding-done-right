import ApplicationServices
import AppKit
import OSLog

/// Reads the Cursor Context of the frontmost app through Accessibility at the
/// start of a Capture Session. It only reads: it posts no key event and does
/// not touch the clipboard, so it cannot put a Stray Character in the app.
struct CursorContextReader: Sendable {

    // MARK: - Constants

    /// Bundle IDs for Electron/Chromium apps that need AXEnhancedUserInterface set to expose text attributes.
    private static let enhancedUIBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "md.obsidian",
    ]

    /// Maximum characters to read before and after cursor for context capture.
    static let contextWindowSize = 200

    /// Maximum marker steps for WebKit path B context capture (safety bound).
    static let maxMarkerSteps = 400

    /// Reads the text before and after the insertion point in the frontmost app.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle ID of the frontmost app.
    ///   - pid: The process ID of the frontmost app.
    /// - Returns: The Cursor Context, or nil if Accessibility cannot read it.
    func read(bundleIdentifier: String?, pid: pid_t?) -> CursorContext? {
        Logger.actions.info("CursorContextReader: reading from \(bundleIdentifier ?? "unknown")")

        // Enable enhanced UI for browsers that need it for AX text exposure
        if let bundleID = bundleIdentifier, Self.enhancedUIBundleIDs.contains(bundleID), let pid = pid {
            enableEnhancedAccessibility(pid: pid)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success, let ref = focusedElementRef else {
            Logger.actions.info("AX capture: no focused element (error: \(focusedResult.rawValue))")
            return nil
        }

        // AXUIElementCopyAttributeValue returns AnyObject; bridge to AXUIElement.
        // AX guarantees the type when returning .success for element attributes.
        // unsafeBitCast avoids as! (force unwrap) and as? (always-succeeds warning for CF types).
        let focusedElement = unsafeBitCast(ref, to: AXUIElement.self)
        return captureCursorContext(element: focusedElement, bundleIdentifier: bundleIdentifier)
    }

    /// Sets AXEnhancedUserInterface on the app element to enable AX text
    /// attributes in Chrome, Brave, Edge, Firefox, and other browser-based apps.
    private func enableEnhancedAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(
            app,
            "AXEnhancedUserInterface" as CFString,
            true as CFBoolean
        )
        if result == .success {
            Logger.actions.info("Enabled AXEnhancedUserInterface for PID \(pid)")
        }
    }

    // MARK: - Cursor Context Capture

    /// Captures cursor context (text before and after cursor) using the focused AX element.
    ///
    /// Two paths are attempted:
    /// - Path A (native Cocoa): Uses kAXSelectedTextRangeAttribute and kAXStringForRangeParameterizedAttribute
    /// - Path B (WebKit): Uses AX text markers for WebKit-based apps
    ///
    /// - Parameters:
    ///   - element: The focused AXUIElement to read context from.
    ///   - bundleIdentifier: The bundle ID of the source app (for staleness checks).
    /// - Returns: CursorContext with before/after text, or nil if AX is unavailable.
    private func captureCursorContext(element: AXUIElement, bundleIdentifier: String?) -> CursorContext? {
        // Try Path A first (native Cocoa)
        if let context = captureCursorContextPathA(element: element, bundleIdentifier: bundleIdentifier) {
            return context
        }

        // Fall back to Path B (WebKit text markers)
        if let context = captureCursorContextPathB(element: element, bundleIdentifier: bundleIdentifier) {
            return context
        }

        return nil
    }

    // MARK: - Path A: Native Cocoa (kAXSelectedTextRangeAttribute)

    /// Path A: Reads cursor context using kAXSelectedTextRangeAttribute.
    /// Works in TextEdit, Notes, Xcode, Obsidian, and browser textareas.
    private func captureCursorContextPathA(element: AXUIElement, bundleIdentifier: String?) -> CursorContext? {
        // Get the selected text range (cursor position when selection is empty)
        var selectedRangeRef: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard rangeResult == .success, let selectedRange = selectedRangeRef else {
            return nil
        }

        // Non-Cocoa text surfaces (Electron, Chromium, custom NSTextInput) can return
        // values that aren't AXValueRef. Unchecked `as!` here previously crashed VCDR
        // on every recording in such apps; bail out instead.
        guard let cfRange = Self.cfRange(fromAXAttributeValue: selectedRange) else {
            Logger.actions.info("Cursor context PathA: selectedRange is not an AXValue/CFRange (bundle=\(bundleIdentifier ?? "nil"))")
            return nil
        }
        let cursorPosition = cfRange.location + cfRange.length

        // Read before text (up to contextWindowSize characters)
        let beforeText = readTextViaStringForRange(
            element: element,
            location: max(0, cursorPosition - Self.contextWindowSize),
            length: min(cursorPosition, Self.contextWindowSize)
        )

        // Read after text (up to contextWindowSize characters)
        // We need to get the full document length first to know how far we can read
        let afterText = readTextViaStringForRange(
            element: element,
            location: cursorPosition,
            length: Self.contextWindowSize
        )

        let context = CursorContext(
            beforeText: beforeText,
            afterText: afterText,
            sourceBundleID: bundleIdentifier
        )

        Logger.actions.info("Cursor context captured via Path A (Cocoa): before=\(beforeText?.count ?? 0), after=\(afterText?.count ?? 0)")
        return context
    }

    /// Helper to read text via kAXStringForRangeParameterizedAttribute.
    private func readTextViaStringForRange(element: AXUIElement, location: CFIndex, length: CFIndex) -> String? {
        guard length > 0 else { return nil }

        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var textRef: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textRef
        )

        guard result == .success, let text = textRef as? String, !text.isEmpty else {
            return nil
        }

        return text
    }

    /// Safely extracts a `CFRange` from a value returned by
    /// `AXUIElementCopyAttributeValue(_, kAXSelectedTextRangeAttribute, _)`.
    ///
    /// Returns nil if the value is not an `AXValueRef` carrying a `.cfRange`.
    /// Exposed at internal visibility so tests can exercise the type-check
    /// without a real `AXUIElement`.
    static func cfRange(fromAXAttributeValue value: AnyObject) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    // MARK: - Path B: WebKit Text Markers

    /// Path B: Reads cursor context using AX text markers.
    /// Works in Safari content views and other WebKit-based apps.
    private func captureCursorContextPathB(element: AXUIElement, bundleIdentifier: String?) -> CursorContext? {
        // Get the selected text marker range
        var markerRangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeRef
        ) == .success, let markerRange = markerRangeRef else {
            return nil
        }

        // For a selection, we need the end marker as the cursor position
        // First, get the start and end markers from the range
        var startMarkerRef: AnyObject?
        var endMarkerRef: AnyObject?

        // Try to get start and end markers from the range
        let startResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStartTextMarkerForTextMarkerRange" as CFString,
            markerRange,
            &startMarkerRef
        )
        let endResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXEndTextMarkerForTextMarkerRange" as CFString,
            markerRange,
            &endMarkerRef
        )

        guard startResult == .success, endResult == .success,
              let startMarker = startMarkerRef, let endMarker = endMarkerRef else {
            // Fall back to using the range itself as the cursor position
            return captureCursorContextPathBSimple(element: element, markerRange: markerRange, bundleIdentifier: bundleIdentifier)
        }

        // Walk backward from start marker to collect before text
        let beforeText = walkAndCollectText(
            element: element,
            startMarker: startMarker,
            direction: .backward,
            maxSteps: Self.contextWindowSize,
            maxCharacters: Self.contextWindowSize
        )

        // Walk forward from end marker to collect after text
        let afterText = walkAndCollectText(
            element: element,
            startMarker: endMarker,
            direction: .forward,
            maxSteps: Self.contextWindowSize,
            maxCharacters: Self.contextWindowSize
        )

        let context = CursorContext(
            beforeText: beforeText,
            afterText: afterText,
            sourceBundleID: bundleIdentifier
        )

        Logger.actions.info("Cursor context captured via Path B (WebKit): before=\(beforeText?.count ?? 0), after=\(afterText?.count ?? 0)")
        return context
    }

    private enum WalkDirection {
        case backward
        case forward
    }

    /// Simple Path B implementation when we can only use the selected range.
    private func captureCursorContextPathBSimple(element: AXUIElement, markerRange: AnyObject, bundleIdentifier: String?) -> CursorContext? {
        // For selection, use the end of the range as cursor position
        // We'll read a window around the selection
        var textRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &textRef
        ) == .success, let selectedText = textRef as? String else {
            return nil
        }

        // Get the text around the selection by expanding the range
        // This is a simplified approach - we return what we have
        // Full implementation would walk markers but this provides basic context
        let context = CursorContext(
            beforeText: nil,  // Would require marker walking
            afterText: nil,   // Would require marker walking
            sourceBundleID: bundleIdentifier
        )

        Logger.actions.info("Cursor context via Path B (simple): limited due to marker range structure")
        return context
    }

    /// Walks text markers in the specified direction and collects text.
    private func walkAndCollectText(
        element: AXUIElement,
        startMarker: AnyObject,
        direction: WalkDirection,
        maxSteps: Int,
        maxCharacters: Int
    ) -> String? {
        var collectedText = ""
        var currentMarker: AnyObject? = startMarker
        var steps = 0
        let stepLimit = min(maxSteps, Self.maxMarkerSteps)

        let nextMarkerAttribute = direction == .backward
            ? "AXPreviousTextMarkerForTextMarker"
            : "AXNextTextMarkerForTextMarker"

        // For backward, we need to walk and collect in reverse order
        var markers: [AnyObject] = []

        while steps < stepLimit, let marker = currentMarker {
            markers.append(marker)

            var nextMarkerRef: AnyObject?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element,
                nextMarkerAttribute as CFString,
                marker,
                &nextMarkerRef
            )

            guard result == .success, let nextMarker = nextMarkerRef else {
                break
            }

            currentMarker = nextMarker
            steps += 1
        }

        // Now extract text from the collected markers
        // For backward direction, we need to reverse the order
        let orderedMarkers = direction == .backward ? markers.reversed() : markers

        for marker in orderedMarkers {
            // Create a range from this marker to itself to get single character
            var singleCharRangeRef: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXTextMarkerRangeForUnorderedTextMarkers" as CFString,
                [marker, marker] as CFArray,
                &singleCharRangeRef
            ) == .success, let charRange = singleCharRangeRef else {
                continue
            }

            var charRef: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXStringForTextMarkerRange" as CFString,
                charRange,
                &charRef
            ) == .success, let char = charRef as? String else {
                continue
            }

            collectedText.append(char)

            if collectedText.count >= maxCharacters {
                break
            }
        }

        return collectedText.isEmpty ? nil : collectedText
    }
}
