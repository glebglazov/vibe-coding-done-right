//
//  ProcessedOutputWindow.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// Window that displays processed output text with keyboard shortcuts
struct ProcessedOutputWindow: View {
    let text: String
    @Binding var isPresented: Bool
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Preview")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Text("Esc to close • ⌘⇧C to copy")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: closeWindow) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Divider()

            // Content
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
        }
        .padding(20)
        .frame(width: 600, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    private func setupKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check for Esc key
            if event.keyCode == 53 { // Esc
                closeWindow()
                return nil
            }

            // Check for Cmd+Shift+C (keyCode 8 is 'c')
            let hasCommand = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)

            if event.keyCode == 8, hasCommand, hasShift {
                copyToClipboard()
                return nil
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closeWindow() {
        isPresented = false
        // Close the actual NSWindow
        if let window = NSApp.windows.first(where: { $0.title == "Processed Output" }) {
            window.close()
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("📋 Copied preview content to clipboard")
    }
}

#Preview {
    ProcessedOutputWindow(
        text: "This is a preview of the processed text.\n\nYou can select and copy any part of this text.\n\nPress Esc to close or Cmd+Shift+C to copy all.",
        isPresented: .constant(true)
    )
}
