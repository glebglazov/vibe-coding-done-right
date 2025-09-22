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

            // Last transcription (clickable to copy)
            if !controller.lastTranscription.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last transcription:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        print("📋 Copying to clipboard: '\(controller.lastTranscription)'")
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        let success = pasteboard.setString(controller.lastTranscription, forType: .string)
                        print("📋 Clipboard copy success: \(success)")
                    }) {
                        Text(controller.lastTranscription)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .buttonStyle(PlainButtonStyle())
                    .help("Click to copy full transcription to clipboard")
                }
                .padding(.horizontal, 4)

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
