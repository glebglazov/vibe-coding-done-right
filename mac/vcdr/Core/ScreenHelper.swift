//
//  ScreenHelper.swift
//  vcdr
//
//  Helper for finding the active/current screen in multi-monitor setups
//

import AppKit

struct ScreenHelper {
    /// Centers the given window on the active screen
    static func centerWindow(_ window: NSWindow, relativeTo app: NSRunningApplication? = nil) {
        let screen = getActiveScreen(for: app)
        let screenFrame = screen.frame
        let windowSize = window.frame.size
        let origin = CGPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )
        window.setFrameOrigin(origin)
    }

    /// Positions the window at bottom-center of the active screen with a margin from bottom
    static func positionWindowAtBottom(_ window: NSWindow, margin: CGFloat, relativeTo app: NSRunningApplication? = nil) {
        let screen = getActiveScreen(for: app)
        let screenFrame = screen.frame
        let windowSize = window.frame.size
        let origin = CGPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.minY + margin
        )
        window.setFrameOrigin(origin)
    }

    /// Returns the best screen for displaying overlays, considering:
    /// 1. Screen where the given app's window is located
    /// 2. Screen containing the mouse cursor
    /// 3. Main screen as final fallback
    static func getActiveScreen(for app: NSRunningApplication? = nil) -> NSScreen {
        // Method 1: Try to find screen where the given app is located
        if let app = app, let appScreen = findScreen(for: app) {
            return appScreen
        }

        // Method 2: Fall back to screen with cursor
        let mouseLocation = NSEvent.mouseLocation
        if let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return cursorScreen
        }

        // Method 3: Fall back to main screen
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Finds the screen containing the given app's main window
    private static func findScreen(for app: NSRunningApplication) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            // Check if this window belongs to the target app
            guard let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  windowOwnerPID == app.processIdentifier else {
                continue
            }

            // Get window bounds
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            let windowFrame = CGRect(x: x, y: y, width: width, height: height)

            // Find which screen contains this window
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) {
                return screen
            }
        }

        return nil
    }
}
