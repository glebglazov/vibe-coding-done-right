//
//  TransientHUD.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// A transient heads-up display that shows status notifications
/// Simple text-based design with grey background
struct TransientHUD: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let isVisible: Bool

    var displayText: String {
        if let subtitle = subtitle {
            return "\(title) | \(subtitle)"
        } else {
            return title
        }
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
            )
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.95)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isVisible)
    }
}

/// Configuration for HUD notification
struct HUDNotification {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let duration: TimeInterval

    init(icon: String, iconColor: Color = .primary, title: String, subtitle: String? = nil, duration: TimeInterval = 2.0) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
    }

    // Helper to get mode emoji
    private static func modeEmoji(for mode: String) -> String {
        return "🤖"
    }

    // Convenience factory methods for common notifications
    static func capturingStarted(mode: String) -> HUDNotification {
        HUDNotification(
            icon: "mic.circle.fill",
            iconColor: .blue,
            title: "\(modeEmoji(for: mode))\(mode)",
            subtitle: "🎤 On"
        )
    }

    static func recordingStarted(mode: String) -> HUDNotification {
        HUDNotification(
            icon: "record.circle.fill",
            iconColor: .red,
            title: "\(modeEmoji(for: mode))\(mode)",
            subtitle: "🔴 On"
        )
    }

    static func recordingStopped(mode: String) -> HUDNotification {
        HUDNotification(
            icon: "stop.circle.fill",
            iconColor: .primary,
            title: "\(modeEmoji(for: mode))\(mode)",
            subtitle: "🔴 Off"
        )
    }

    static func modeChanged(to mode: String, isRecording: Bool) -> HUDNotification {
        HUDNotification(
            icon: "sparkles",
            iconColor: .purple,
            title: "\(modeEmoji(for: mode))\(mode)",
            subtitle: isRecording ? "🔴 On" : "🔴 Off"
        )
    }

    static func processing() -> HUDNotification {
        HUDNotification(
            icon: "waveform.circle",
            iconColor: .blue,
            title: "⏳ Processing",
            subtitle: nil,
            duration: 1.5
        )
    }

    static func clipboardAdded() -> HUDNotification {
        HUDNotification(
            icon: "doc.on.clipboard",
            iconColor: .green,
            title: "📋 Clipboard Added",
            subtitle: nil,
            duration: 1.5
        )
    }

    static func processingStarted(mode: String) -> HUDNotification {
        HUDNotification(
            icon: "gearshape.fill",
            iconColor: .blue,
            title: "⚙️ Processing",
            subtitle: mode,
            duration: 2.0
        )
    }

    static func sendingComplete(destination: String) -> HUDNotification {
        HUDNotification(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            title: "✅ Sent",
            subtitle: destination,
            duration: 2.0
        )
    }
}

#Preview {
    VStack(spacing: 40) {
        TransientHUD(
            icon: "record.circle.fill",
            iconColor: .red,
            title: "🤖Assistant",
            subtitle: "🔴 On",
            isVisible: true
        )

        TransientHUD(
            icon: "stop.circle.fill",
            iconColor: .primary,
            title: "🤖Assistant",
            subtitle: "🔴 Off",
            isVisible: true
        )

        TransientHUD(
            icon: "sparkles",
            iconColor: .purple,
            title: "🤖Custom Mode",
            subtitle: nil,
            isVisible: true
        )

        TransientHUD(
            icon: "mic.circle.fill",
            iconColor: .blue,
            title: "🤖Disabled",
            subtitle: "🎤 On",
            isVisible: true
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.5))
}
