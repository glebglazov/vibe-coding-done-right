import ApplicationServices
import AppKit
import OSLog

struct SelectionCapturer: Sendable {

    // MARK: - Types

    /// Result of a capture operation containing both selected text and cursor context.
    /// Cursor context is captured alongside selection to reuse the same AX focused element lookup,
    /// saving 10-100ms and eliminating race conditions between separate AX calls.
    struct CaptureResult: Equatable, Sendable {
        let selectedText: String?
        let cursorContext: CursorContext?

        init(selectedText: String?, cursorContext: CursorContext?) {
            self.selectedText = selectedText
            self.cursorContext = cursorContext
        }
    }

    // MARK: - Constants

    /// Bundle IDs for Electron/Chromium apps that need AXEnhancedUserInterface set to expose text selection.
    private static let enhancedUIBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "md.obsidian",
    ]

    /// Virtual key code for C key — used to identify the Copy menu item locale-independently
    /// and for CGEvent Cmd+C simulation.
    static let cVirtualKeyCode: UInt16 = 8
    /// Maximum time to wait for the clipboard to update after pressing Copy.
    private static let clipboardPollTimeout: Duration = .milliseconds(300)
    /// Interval between clipboard changeCount polls.
    private static let clipboardPollInterval: Duration = .milliseconds(20)
    /// Time for the system sound server to pick up alert volume changes.
    private static let alertVolumeSettleDelay: Duration = .milliseconds(30)

    /// Reads the currently selected text in the frontmost app.
    ///
    /// Strategy (in order):
    /// 1. AX direct — reads kAXSelectedTextAttribute or AXSelectedTextMarkerRange
    /// 2. AX Edit menu — finds Copy in the menu bar, checks if enabled, presses it via AXPress
    /// 3. Cmd+C with muted alert volume — for apps where AX is completely unsupported (e.g. Telegram)
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle ID of the frontmost app.
    ///   - pid: The process ID of the frontmost app.
    /// - Returns: The selected text, or nil if nothing is selected.
    /// Maximum characters to include in diagnostic log messages.
    private static let logPreviewLength = 80

    /// Maximum characters to read before and after cursor for context capture.
    static let contextWindowSize = 200

    /// Maximum marker steps for WebKit path B context capture (safety bound).
    static let maxMarkerSteps = 400

    /// Captures both the selected text and cursor context from the frontmost app.
    ///
    /// Cursor context is captured alongside selection to reuse the same AX focused element lookup,
    /// saving 10-100ms and eliminating a race condition where separate calls could see different
    /// focused elements.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle ID of the frontmost app.
    ///   - pid: The process ID of the frontmost app.
    /// - Returns: A `CaptureResult` containing selected text and cursor context (both may be nil).
    func capture(bundleIdentifier: String?, pid: pid_t?) async -> CaptureResult {
        let appName = bundleIdentifier ?? "unknown"
        Logger.actions.info("SelectionCapturer: starting capture from \(appName)")

        // Enable enhanced UI for browsers that need it for AX text exposure
        if let bundleID = bundleIdentifier, Self.enhancedUIBundleIDs.contains(bundleID), let pid = pid {
            enableEnhancedAccessibility(pid: pid)
        }

        // Layer 1: Try AX direct (fastest, no clipboard interaction)
        let axResult = captureViaAccessibility(bundleIdentifier: bundleIdentifier)

        switch axResult.selectedResult {
        case .captured(let text):
            Logger.actions.info("SelectionCapturer: result from AX direct: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            return CaptureResult(selectedText: text, cursorContext: axResult.cursorContext)
        case .confirmedEmpty:
            // AX confirmed cursor is positioned but nothing is selected.
            // Skip clipboard-based layers — apps like Obsidian and VS Code copy the
            // entire current line on Cmd+C when nothing is selected, producing false captures.
            Logger.actions.info("SelectionCapturer: AX confirmed empty selection, skipping clipboard layers")
            return CaptureResult(selectedText: nil, cursorContext: axResult.cursorContext)
        case .unavailable:
            break
        }

        // Layer 2: Try Edit > Copy via AX menu bar (works for apps with standard menus)
        if let pid = pid, let text = await captureViaEditMenu(pid: pid) {
            Logger.actions.info("SelectionCapturer: result from Edit menu: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            // Context capture not available via menu bar path
            return CaptureResult(selectedText: text, cursorContext: nil)
        }

        // Layer 3: Cmd+C with muted alert volume (last resort for apps like Telegram
        // where AX is completely unsupported)
        if let text = await captureViaCmdC() {
            Logger.actions.info("SelectionCapturer: result from Cmd+C: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            // Context capture not available via Cmd+C path
            return CaptureResult(selectedText: text, cursorContext: nil)
        }

        Logger.actions.info("SelectionCapturer: no text captured from any layer")
        return CaptureResult(selectedText: nil, cursorContext: nil)
    }

    // MARK: - Layer 1: Accessibility Direct

    /// Result of the AX direct capture attempt for selection only.
    private enum AXSelectionResult {
        /// AX returned selected text.
        case captured(String)
        /// AX successfully queried the element but selection is empty (cursor with no selection).
        /// Clipboard-based layers should be skipped — apps like Obsidian copy the current line
        /// on Cmd+C when nothing is selected, producing false captures.
        case confirmedEmpty
        /// AX could not access the element or attribute. Fall through to clipboard layers.
        case unavailable
    }

    /// Combined result from AX direct capture containing both selection and cursor context.
    private struct AXDirectResult {
        let selectedResult: AXSelectionResult
        let cursorContext: CursorContext?
    }

    /// Reads selected text via AX attributes and captures cursor context.
    /// Tries kAXSelectedTextAttribute first, then falls back to AXSelectedTextMarkerRange for WebKit-based apps.
    private func captureViaAccessibility(bundleIdentifier: String?) -> AXDirectResult {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success else {
            Logger.actions.info("AX capture: no focused element (error: \(focusedResult.rawValue))")
            return AXDirectResult(selectedResult: .unavailable, cursorContext: nil)
        }

        // AXUIElementCopyAttributeValue returns AnyObject; bridge to AXUIElement.
        // AX guarantees the type when returning .success for element attributes.
        // unsafeBitCast avoids as! (force unwrap) and as? (always-succeeds warning for CF types).
        guard let ref = focusedElementRef else {
            return AXDirectResult(selectedResult: .unavailable, cursorContext: nil)
        }
        let focusedElement = unsafeBitCast(ref, to: AXUIElement.self)

        // Capture cursor context first (uses the same focused element)
        let cursorContext = captureCursorContext(element: focusedElement, bundleIdentifier: bundleIdentifier)

        // Try standard kAXSelectedTextAttribute (works in native Cocoa apps)
        var selectedTextRef: AnyObject?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        )
        if selectedTextResult == .success, let text = selectedTextRef as? String {
            if !text.isEmpty {
                Logger.actions.info("Captured selection via AX direct (\(text.count) chars)")
                return AXDirectResult(selectedResult: .captured(text), cursorContext: cursorContext)
            }
            // AX returned empty string — cursor is positioned but nothing is selected.
            Logger.actions.info("AX capture: selected text attribute is empty (no selection)")
            return AXDirectResult(selectedResult: .confirmedEmpty, cursorContext: cursorContext)
        }

        // Try text marker range (works in WebKit/browser content views)
        var markerRangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRangeRef
        ) == .success, let markerRange = markerRangeRef {
            var textRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                focusedElement,
                "AXStringForTextMarkerRange" as CFString,
                markerRange,
                &textRef
            ) == .success, let text = textRef as? String, !text.isEmpty {
                Logger.actions.info("Captured selection via AX text marker (\(text.count) chars)")
                return AXDirectResult(selectedResult: .captured(text), cursorContext: cursorContext)
            }
        }

        Logger.actions.info("AX capture: no selected text found")
        return AXDirectResult(selectedResult: .unavailable, cursorContext: cursorContext)
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

    // MARK: - Layer 2: Edit Menu Copy

    /// Captures selected text by pressing the Copy menu item via AXPress.
    /// Only presses Copy if the menu item exists and is enabled (indicating a selection).
    /// AXPress invokes the menu action directly — no keyboard events, no menu flash.
    private func captureViaEditMenu(pid: pid_t) async -> String? {
        let app = AXUIElementCreateApplication(pid)

        // Get the app's menu bar
        var menuBarRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXMenuBarAttribute as CFString,
            &menuBarRef
        ) == .success else {
            Logger.actions.info("Edit menu capture: cannot access menu bar")
            return nil
        }
        guard let ref = menuBarRef else { return nil }
        let menuBar = unsafeBitCast(ref, to: AXUIElement.self)

        // Find the Copy menu item by its keyboard shortcut (Cmd+C), locale-independent
        guard let copyItem = findCopyMenuItem(in: menuBar) else {
            Logger.actions.info("Edit menu capture: Copy menu item not found")
            return nil
        }

        // Check if Copy is enabled — disabled means nothing is selected
        guard axIsEnabled(copyItem) else {
            Logger.actions.info("Edit menu capture: Copy is disabled (no selection)")
            return nil
        }

        // Save clipboard state before pressing Copy
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousContents = pasteboard.string(forType: .string)

        // Press Copy via AX — no keyboard events, no menu flash
        let pressResult = AXUIElementPerformAction(copyItem, kAXPressAction as CFString)
        guard pressResult == .success else {
            Logger.actions.warning("Edit menu capture: AXPress failed (error: \(pressResult.rawValue))")
            return nil
        }

        // Wait for clipboard to update
        let captured = await pollForClipboardChange(previousChangeCount: previousChangeCount)

        if let text = captured, !text.isEmpty {
            // Restore previous clipboard contents only when Copy actually changed the clipboard.
            // Skipping restore when clipboard is unchanged avoids unnecessary changeCount bumps
            // that can race with ClipboardMonitor's polling.
            pasteboard.clearContents()
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
            Logger.actions.info("Captured selection via Edit menu (\(text.count) chars)")
            return text
        }

        Logger.actions.info("Edit menu capture: clipboard unchanged after pressing Copy")
        return nil
    }

    // MARK: - Layer 3: Cmd+C with Alert Volume Muting

    /// Last-resort capture for apps where AX is completely unsupported (e.g. Telegram).
    /// Mutes the system alert volume before simulating Cmd+C to suppress the "bonk"
    /// sound when nothing is selected, then restores the original volume.
    private func captureViaCmdC() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousContents = pasteboard.string(forType: .string)

        // Mute alert sounds before simulating Cmd+C
        let originalVolume = readAlertVolume()
        if originalVolume != nil {
            setAlertVolume(0)
            // Wait for system sound server to pick up the change
            try? await Task.sleep(for: Self.alertVolumeSettleDelay)
        }

        Logger.actions.info("Cmd+C fallback (alert volume muted)")
        KeyboardSimulator.simulateCmdC()

        let captured = await pollForClipboardChange(previousChangeCount: previousChangeCount)

        // Restore alert volume
        if let volume = originalVolume {
            setAlertVolume(volume)
        }

        if let text = captured, !text.isEmpty {
            // Restore previous clipboard contents only when Cmd+C actually changed the clipboard.
            // Skipping restore when clipboard is unchanged avoids unnecessary changeCount bumps
            // that can race with ClipboardMonitor's polling.
            pasteboard.clearContents()
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
            Logger.actions.info("Captured selection via Cmd+C (\(text.count) chars)")
            return text
        }

        Logger.actions.info("Cmd+C fallback: no text captured (clipboard unchanged)")
        return nil
    }

    // MARK: - Alert Volume Helpers

    /// Reads the current system alert volume via `osascript`.
    /// Returns the volume (0-100) or nil if the script fails.
    private func readAlertVolume() -> Int? {
        let script = "tell application \"System Events\" to return alert volume of (get volume settings)"
        guard let output = runOsascript(script) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sets the system alert volume via `osascript`.
    private func setAlertVolume(_ volume: Int) {
        _ = runOsascript("set volume alert volume \(volume)")
    }

    /// Runs an AppleScript string via /usr/bin/osascript and returns stdout.
    private func runOsascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            Logger.actions.warning("osascript failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Clipboard Polling

    /// Polls `NSPasteboard.changeCount` until it differs from `previousChangeCount`
    /// or the timeout elapses. Returns the new clipboard string if the count changed.
    private func pollForClipboardChange(previousChangeCount: Int) async -> String? {
        let deadline = ContinuousClock.now + Self.clipboardPollTimeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount != previousChangeCount {
                return NSPasteboard.general.string(forType: .string)
            }
            try? await Task.sleep(for: Self.clipboardPollInterval)
        }
        return nil
    }

}
