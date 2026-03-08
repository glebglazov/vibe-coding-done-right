import AppKit

/// NSPanel subclass that accepts key events.
/// Used by ModeSwitcherPanel, PushToTypePanel, OutputPanelPanel, and RecordingIndicatorPanel.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
