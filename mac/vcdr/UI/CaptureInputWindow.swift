//
//  CaptureInputWindow.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// Displays a window showing all captured inputs
/// Can be used for current session or historical captures
struct CaptureInputWindow: View {
    let actions: [CaptureAction]
    let title: String

    init(actions: [CaptureAction], title: String = "Captured Input") {
        self.actions = actions
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(actions.count) action\(actions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Actions list
            if actions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No actions yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Start recording or add clipboard text")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(actions) { action in
                            CaptureActionRow(action: action)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}

/// A row displaying a single capture action
struct CaptureActionRow: View {
    let action: CaptureAction

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: action.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with source and timestamp
            HStack {
                Image(systemName: action.sourceIcon)
                    .foregroundColor(sourceColor)
                    .font(.caption)

                Text(action.sourceDescription)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Spacer()

                Text(formattedTimestamp)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if action.audioFileURL != nil {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundColor(.blue)
                        .font(.caption2)
                        .help("Has audio file")
                }
            }

            // Text content
            Text(action.text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(sourceColor.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var sourceColor: Color {
        switch action.source {
        case .clipboard:
            return .blue
        case .recording:
            return .red
        case .selectedText:
            return .green
        case .keyboardInput:
            return .blue
        }
    }
}

#Preview {
    let sampleActions = [
        CaptureAction(source: .selectedText, text: "Wikipedia"),
        CaptureAction(source: .recording, text: "Explain that to me", audioFileURL: URL(fileURLWithPath: "/tmp/test.wav")),
        CaptureAction(source: .clipboard, text: "Anthropic"),
        CaptureAction(source: .recording, text: "What that company's doing?", audioFileURL: URL(fileURLWithPath: "/tmp/test2.wav"))
    ]

    CaptureInputWindow(actions: sampleActions, title: "Current Capture")
}
