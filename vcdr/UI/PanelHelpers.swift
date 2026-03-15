import AppKit

// MARK: - Panel Positioning

/// Computes the origin point for a panel centered horizontally and positioned just below the menu bar.
/// Used by CapturePanel, RecordingIndicatorPanel, and ModeSwitcherPanel.
func panelOriginBelowMenuBar(width: CGFloat, height: CGFloat, offset: CGFloat = 8) -> NSPoint? {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
    let screenFrame = screen.frame
    let visibleFrame = screen.visibleFrame
    let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
    let x = screenFrame.midX - width / 2
    let y = screenFrame.maxY - menuBarHeight - height - offset
    return NSPoint(x: x, y: y)
}

// MARK: - NSPanel Configuration

extension NSPanel {
    /// Configures common overlay panel properties shared by CapturePanel, RecordingIndicatorPanel, and ModeSwitcherPanel.
    func configureAsOverlay(hasShadow: Bool = false, ignoresMouseEvents: Bool = false) {
        isOpaque = false
        backgroundColor = .clear
        self.hasShadow = hasShadow
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        self.ignoresMouseEvents = ignoresMouseEvents
    }
}

// MARK: - Event Monitor Cleanup

/// Removes an NSEvent monitor and sets the reference to nil.
/// Encapsulates the repeated `if let monitor { NSEvent.removeMonitor(monitor); ref = nil }` pattern.
func removeEventMonitor(_ monitor: inout Any?) {
    if let m = monitor {
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}
