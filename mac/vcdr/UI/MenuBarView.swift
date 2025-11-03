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
    @ObservedObject var captureHistory = CaptureHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            // Start/Stop Capturing
            Button(action: {
                controller.toggleCapture()
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

            // History
            Button("History...") {
                openWindow(id: "history")
                // Activate the app to bring history window to foreground
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Divider()

            // Status (if not ready)
            if !controller.statusMessage.isEmpty && !["Ready to record", "Ready to capture"].contains(controller.statusMessage) {
                Text(controller.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()
            }

            // Last capture (clickable to copy processed output)
            if let lastCapture = captureHistory.entries.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last capture:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        print("📋 Copying processed output to clipboard")
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        let success = pasteboard.setString(lastCapture.processedOutput, forType: .string)
                        print("📋 Clipboard copy success: \(success)")
                    }) {
                        Text(lastCapture.inputText.components(separatedBy: "\n").first ?? "")
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
                    .help("Click to copy processed output to clipboard")
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
        if controller.isCapturing {
            return "stop.fill" // Show stop icon when capturing
        } else {
            return "mic.fill"
        }
    }

    private var buttonText: String {
        if controller.isInitializing {
            return "Initializing..."
        } else if controller.isProcessing {
            return "Processing..."
        } else if controller.isCapturing {
            return "Finish"
        } else {
            return "Start Capturing"
        }
    }

}
