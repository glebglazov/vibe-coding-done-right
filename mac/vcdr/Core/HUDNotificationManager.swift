//
//  HUDNotificationManager.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI
import Combine

/// Manages the display of transient HUD notifications
@MainActor
class HUDNotificationManager: ObservableObject {
    @Published var currentNotification: HUDNotification?
    @Published var isVisible = false
    @Published var shouldShowWindow = false

    private var hideTask: Task<Void, Never>?

    /// Show a HUD notification
    /// - Parameter notification: The notification to display
    func show(_ notification: HUDNotification) {
        // Cancel any existing hide task
        hideTask?.cancel()

        // Update the notification and show it
        currentNotification = notification
        shouldShowWindow = true
        isVisible = true

        print("📢 HUD: \(notification.title) - \(notification.subtitle ?? "")")

        // Schedule auto-hide
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(notification.duration * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await MainActor.run {
                hide()
            }
        }
    }

    /// Hide the current notification
    func hide() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = false

        // Clear the notification after animation completes
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s for animation
            guard !isVisible else { return } // Don't clear if shown again
            currentNotification = nil
            shouldShowWindow = false
        }
    }

    /// Convenience methods for common notifications
    func showCapturingStarted(mode: String) {
        show(.capturingStarted(mode: mode))
    }

    func showRecordingStarted(mode: String) {
        show(.recordingStarted(mode: mode))
    }

    func showRecordingStopped(mode: String) {
        show(.recordingStopped(mode: mode))
    }

    func showModeChanged(to mode: String, isRecording: Bool) {
        show(.modeChanged(to: mode, isRecording: isRecording))
    }

    func showProcessing() {
        show(.processing())
    }
}
