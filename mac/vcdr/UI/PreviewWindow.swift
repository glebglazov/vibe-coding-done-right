//
//  PreviewWindow.swift
//  vcdr
//
//  Created by Gleb Glazov on 27/10/25.
//

import SwiftUI

struct PreviewWindow: View {
    @EnvironmentObject var controller: MenuBarController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and copy button
            HStack {
                Text("Tool Response Preview")
                    .font(.headline)

                Spacer()

                Button(action: copyToClipboard) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content area
            ScrollView {
                if controller.lastToolResponse.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("No tool response available")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Text("Record and process audio to see the result here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    Text(controller.lastToolResponse)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(width: 600, height: 400)
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controller.lastToolResponse, forType: .string)

        // Optional: Show a brief confirmation
        print("📋 Copied tool response to clipboard")
    }
}

#Preview {
    PreviewWindow()
        .environmentObject(MenuBarController())
}
