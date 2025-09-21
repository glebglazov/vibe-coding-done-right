//
//  MenuBarView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var controller: MenuBarController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Start/Stop Recording
            Button(action: {
                controller.toggleRecording()
            }) {
                Label(buttonText, systemImage: buttonIcon)
            }
            .disabled(controller.isProcessing || controller.isInitializing)

            Divider()

            // Settings
            Button("Settings...") {
                openWindow(id: "settings")
                // Activate the app to bring settings window to foreground
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Divider()

            // Status (if not ready)
            if !controller.statusMessage.isEmpty && controller.statusMessage != "Ready to record" {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()
            }

            // Last transcription (shortened)
            if !controller.lastTranscription.isEmpty {
                Button("Last: \(String(controller.lastTranscription.prefix(30)))\(controller.lastTranscription.count > 30 ? "..." : "")") {
                    NSPasteboard.general.setString(controller.lastTranscription, forType: .string)
                }
                .help("Click to copy full transcription")

                Divider()
            }

            // Quit
            Button("Quit vcdr") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var buttonIcon: String {
        if controller.isInitializing {
            return "arrow.down.circle"
        } else if controller.isProcessing {
            return "hourglass"
        } else if controller.isRecording {
            return "stop.fill"
        } else {
            return "mic.fill"
        }
    }

    private var buttonText: String {
        if controller.isInitializing {
            return "Initializing..."
        } else if controller.isProcessing {
            return "Processing..."
        } else if controller.isRecording {
            return "Stop Recording"
        } else {
            return "Start Recording"
        }
    }

    private var buttonColor: Color {
        if controller.isInitializing {
            return .gray
        } else if controller.isProcessing {
            return .orange
        } else if controller.isRecording {
            return .red
        } else {
            return .green
        }
    }
}
