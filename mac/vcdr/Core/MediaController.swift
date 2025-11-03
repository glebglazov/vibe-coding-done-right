//
//  MediaController.swift
//  vcdr
//
//  Helper for pausing/resuming system media playback during recording
//

import Foundation
import CoreGraphics

class MediaController {
    private var wasPlayingBeforeRecording = false

    /// Pauses any playing media by simulating play/pause key
    func pauseMedia() {
        print("⏸️ MediaController: Pausing media playback")
        // Assume media was playing if we're pausing it
        wasPlayingBeforeRecording = true
        sendPlayPauseKey()
    }

    /// Resumes media if it was playing before
    func resumeMediaIfNeeded() {
        guard wasPlayingBeforeRecording else {
            print("⏯️ MediaController: Media was not playing, skipping resume")
            return
        }

        print("▶️ MediaController: Resuming media playback")
        sendPlayPauseKey()
        wasPlayingBeforeRecording = false
    }

    /// Sends the play/pause media key event
    private func sendPlayPauseKey() {
        // NX_KEYTYPE_PLAY = 16
        // Play/Pause is key code 16 in the system-defined media keys
        let keyCode: CGKeyCode = 16

        // Create key down event
        guard let keyDownEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ) else {
            print("❌ MediaController: Failed to create key down event")
            return
        }

        // Create key up event
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            print("❌ MediaController: Failed to create key up event")
            return
        }

        // Set the event type to system-defined (for media keys)
        keyDownEvent.type = .keyDown
        keyUpEvent.type = .keyUp

        // Post the events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)

        print("✅ MediaController: Play/pause key sent")
    }
}
