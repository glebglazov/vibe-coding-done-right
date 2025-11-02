//
//  KeyboardInputOverlay.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI
import AppKit

/// Overlay for capturing keyboard text input during a capture session
struct KeyboardInputOverlay: View {
    @Binding var isPresented: Bool
    let onSubmit: (String) -> Void

    @State private var inputText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Keyboard Input")
                .font(.headline)
                .foregroundColor(.primary)

            TextField("Type your input...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit {
                    submitInput()
                }

            HStack(spacing: 8) {
                Text("Press")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Enter")
                    .font(.caption.bold())
                    .foregroundColor(.blue)

                Text("to submit,")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Esc")
                    .font(.caption.bold())
                    .foregroundColor(.gray)

                Text("to cancel")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Focus the text field when window appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onExitCommand {
            // Handle Escape key
            cancelInput()
        }
    }

    private func submitInput() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Don't submit empty input
            return
        }

        onSubmit(inputText)
        inputText = ""
        isPresented = false
        closeWindow()
    }

    private func cancelInput() {
        inputText = ""
        isPresented = false
        closeWindow()
    }

    private func closeWindow() {
        // Find and close the keyboard input window
        if let window = NSApp.windows.first(where: { $0.title == "Add Keyboard Input" }) {
            window.close()
        }
    }
}

#Preview {
    KeyboardInputOverlay(
        isPresented: .constant(true),
        onSubmit: { text in
            print("Submitted: \(text)")
        }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.3))
}
