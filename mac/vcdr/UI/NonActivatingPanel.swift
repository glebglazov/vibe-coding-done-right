//
//  NonActivatingPanel.swift
//  vcdr
//
//  Created by Claude Code
//

import AppKit

/// A custom NSPanel that doesn't activate the application when clicked
/// This allows buttons to work without stealing focus from other apps
class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}
