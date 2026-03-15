import ApplicationServices
import AppKit
import OSLog

struct SelectionCapturer: Sendable {

    // MARK: - Constants

    /// Browser bundle IDs that need AXEnhancedUserInterface set to expose text selection.
    private static let enhancedUIBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    /// Virtual key code for C key — used to identify the Copy menu item locale-independently
    /// and for CGEvent Cmd+C simulation.
    private static let cVirtualKeyCode: UInt16 = 8
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
    func capture(bundleIdentifier: String?, pid: pid_t?) async -> String? {
        // Enable enhanced UI for browsers that need it for AX text exposure
        if let bundleID = bundleIdentifier, Self.enhancedUIBundleIDs.contains(bundleID), let pid = pid {
            enableEnhancedAccessibility(pid: pid)
        }

        // Layer 1: Try AX direct (fastest, no clipboard interaction)
        if let text = captureViaAccessibility() {
            return text
        }

        // Layer 2: Try Edit > Copy via AX menu bar (works for apps with standard menus)
        if let pid = pid, let text = await captureViaEditMenu(pid: pid) {
            return text
        }

        // Layer 3: Cmd+C with muted alert volume (last resort for apps like Telegram
        // where AX is completely unsupported)
        return await captureViaCmdC()
    }

    // MARK: - Layer 1: Accessibility Direct

    /// Reads selected text via AX attributes. Tries kAXSelectedTextAttribute first,
    /// then falls back to AXSelectedTextMarkerRange for WebKit-based apps.
    private func captureViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElementRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard focusedResult == .success else {
            Logger.actions.info("AX capture: no focused element (error: \(focusedResult.rawValue))")
            return nil
        }

        // AXUIElementCopyAttributeValue returns AnyObject; cast to AXUIElement.
        // Safe: AX guarantees the type when returning .success for element attributes.
        let focusedElement = focusedElementRef as! AXUIElement

        // Try standard kAXSelectedTextAttribute (works in native Cocoa apps)
        var selectedTextRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        ) == .success, let text = selectedTextRef as? String, !text.isEmpty {
            Logger.actions.info("Captured selection via AX direct (\(text.count) chars)")
            return text
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
                return text
            }
        }

        Logger.actions.info("AX capture: no selected text found")
        return nil
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
        let menuBar = menuBarRef as! AXUIElement

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

        // Restore previous clipboard contents
        pasteboard.clearContents()
        if let previous = previousContents {
            pasteboard.setString(previous, forType: .string)
        }

        if let text = captured, !text.isEmpty {
            Logger.actions.info("Captured selection via Edit menu (\(text.count) chars)")
            return text
        }

        Logger.actions.info("Edit menu capture: clipboard unchanged after pressing Copy")
        return nil
    }

    // MARK: - AX Menu Helpers

    /// Finds the Copy menu item by looking for a menu item with the Cmd+C keyboard shortcut.
    /// Searches all top-level menus. Locale-independent: matches by virtual key code, not title.
    private func findCopyMenuItem(in menuBar: AXUIElement) -> AXUIElement? {
        for barItem in axChildren(of: menuBar) {
            guard let menu = axChildren(of: barItem).first else { continue }
            if let copyItem = findCopyInMenu(menu) {
                return copyItem
            }
        }
        return nil
    }

    /// Searches a single menu for an item with the Cmd+C keyboard shortcut.
    /// Matches virtual key code 8 (C key) with no additional modifiers (Command is implicit).
    private func findCopyInMenu(_ menu: AXUIElement) -> AXUIElement? {
        for item in axChildren(of: menu) {
            var cmdKeyRef: AnyObject?
            guard AXUIElementCopyAttributeValue(
                item,
                "AXMenuItemCmdVirtualKey" as CFString,
                &cmdKeyRef
            ) == .success, let keyCode = cmdKeyRef as? Int, keyCode == Self.cVirtualKeyCode else {
                continue
            }

            // AXMenuItemCmdModifiers: 0 = Command only (Command is implicit in menu shortcuts)
            var modRef: AnyObject?
            if AXUIElementCopyAttributeValue(
                item,
                "AXMenuItemCmdModifiers" as CFString,
                &modRef
            ) == .success, let mods = modRef as? Int, mods == 0 {
                return item
            }
        }
        return nil
    }

    // MARK: - AX Utility Helpers

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success, let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func axIsEnabled(_ element: AXUIElement) -> Bool {
        var enabledRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &enabledRef
        ) == .success else {
            return false
        }
        return CFBooleanGetValue(enabledRef as! CFBoolean)
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
        simulateCmdC()

        let captured = await pollForClipboardChange(previousChangeCount: previousChangeCount)

        // Restore alert volume
        if let volume = originalVolume {
            setAlertVolume(volume)
        }

        // Restore previous clipboard contents
        pasteboard.clearContents()
        if let previous = previousContents {
            pasteboard.setString(previous, forType: .string)
        }

        if let text = captured, !text.isEmpty {
            Logger.actions.info("Captured selection via Cmd+C (\(text.count) chars)")
            return text
        }

        Logger.actions.info("Cmd+C fallback: no text captured (clipboard unchanged)")
        return nil
    }

    /// Simulates Cmd+C via CGEvent. Delegates to KeyboardSimulator for the actual keystroke.
    private func simulateCmdC() {
        KeyboardSimulator.simulateCmdC()
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
