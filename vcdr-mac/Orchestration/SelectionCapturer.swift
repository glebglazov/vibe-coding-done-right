import ApplicationServices
import AppKit
import OSLog

struct SelectionCapturer: Sendable {

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

    func capture(bundleIdentifier: String?, pid: pid_t?) async -> String? {
        let appName = bundleIdentifier ?? "unknown"
        Logger.actions.info("SelectionCapturer: starting capture from \(appName)")

        // Enable enhanced UI for browsers that need it for AX text exposure
        if let bundleID = bundleIdentifier, Self.enhancedUIBundleIDs.contains(bundleID), let pid = pid {
            enableEnhancedAccessibility(pid: pid)
        }

        // Layer 1: Try AX direct (fastest, no clipboard interaction)
        switch captureViaAccessibility() {
        case .captured(let text):
            Logger.actions.info("SelectionCapturer: result from AX direct: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            return text
        case .confirmedEmpty:
            // AX confirmed cursor is positioned but nothing is selected.
            // Skip clipboard-based layers — apps like Obsidian and VS Code copy the
            // entire current line on Cmd+C when nothing is selected, producing false captures.
            Logger.actions.info("SelectionCapturer: AX confirmed empty selection, skipping clipboard layers")
            return nil
        case .unavailable:
            break
        }

        // Layer 2: Try Edit > Copy via AX menu bar (works for apps with standard menus)
        if let pid = pid, let text = await captureViaEditMenu(pid: pid) {
            Logger.actions.info("SelectionCapturer: result from Edit menu: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            return text
        }

        // Layer 3: Cmd+C with muted alert volume (last resort for apps like Telegram
        // where AX is completely unsupported)
        if let text = await captureViaCmdC() {
            Logger.actions.info("SelectionCapturer: result from Cmd+C: \"\(text.prefix(Self.logPreviewLength))\" (\(text.count) chars)")
            return text
        }

        Logger.actions.info("SelectionCapturer: no text captured from any layer")
        return nil
    }

    // MARK: - Layer 1: Accessibility Direct

    /// Result of the AX direct capture attempt.
    private enum AXCaptureResult {
        /// AX returned selected text.
        case captured(String)
        /// AX successfully queried the element but selection is empty (cursor with no selection).
        /// Clipboard-based layers should be skipped — apps like Obsidian copy the current line
        /// on Cmd+C when nothing is selected, producing false captures.
        case confirmedEmpty
        /// AX could not access the element or attribute. Fall through to clipboard layers.
        case unavailable
    }

    /// Reads selected text via AX attributes. Tries kAXSelectedTextAttribute first,
    /// then falls back to AXSelectedTextMarkerRange for WebKit-based apps.
    private func captureViaAccessibility() -> AXCaptureResult {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success else {
            Logger.actions.info("AX capture: no focused element (error: \(focusedResult.rawValue))")
            return .unavailable
        }

        // AXUIElementCopyAttributeValue returns AnyObject; bridge to AXUIElement.
        // AX guarantees the type when returning .success for element attributes.
        // unsafeBitCast avoids as! (force unwrap) and as? (always-succeeds warning for CF types).
        guard let ref = focusedElementRef else { return .unavailable }
        let focusedElement = unsafeBitCast(ref, to: AXUIElement.self)

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
                return .captured(text)
            }
            // AX returned empty string — cursor is positioned but nothing is selected.
            Logger.actions.info("AX capture: selected text attribute is empty (no selection)")
            return .confirmedEmpty
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
                return .captured(text)
            }
        }

        Logger.actions.info("AX capture: no selected text found")
        return .unavailable
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
