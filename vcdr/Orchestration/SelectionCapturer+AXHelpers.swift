import ApplicationServices
import AppKit
import OSLog

// MARK: - AX Menu Helpers

extension SelectionCapturer {

    /// Finds the Copy menu item by looking for a menu item with the Cmd+C keyboard shortcut.
    /// Searches all top-level menus. Locale-independent: matches by virtual key code, not title.
    func findCopyMenuItem(in menuBar: AXUIElement) -> AXUIElement? {
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

    func axChildren(of element: AXUIElement) -> [AXUIElement] {
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

    func axIsEnabled(_ element: AXUIElement) -> Bool {
        var enabledRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &enabledRef
        ) == .success else {
            return false
        }
        guard let enabled = enabledRef as? NSNumber else { return false }
        return enabled.boolValue
    }

    /// Sets AXEnhancedUserInterface on the app element to enable AX text
    /// attributes in Chrome, Brave, Edge, Firefox, and other browser-based apps.
    func enableEnhancedAccessibility(pid: pid_t) {
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
}
