//
//  HistoryView.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// Main history view with master-detail layout (like Apple Notes)
struct HistoryView: View {
    @ObservedObject var captureHistory = CaptureHistory.shared
    @State private var selectedEntry: CaptureHistoryEntry?

    var body: some View {
        NavigationSplitView {
            // Left sidebar - List of entries
            HistoryListView(
                entries: captureHistory.entries,
                selectedEntry: $selectedEntry
            )
        } detail: {
            // Right detail view
            if let entry = selectedEntry {
                HistoryDetailView(entry: entry)
            } else {
                VStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                        .padding()
                    Text("Select a capture to view details")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Capture History")
        .frame(minWidth: 800, minHeight: 600)
    }
}

/// List view showing all history entries
struct HistoryListView: View {
    let entries: [CaptureHistoryEntry]
    @Binding var selectedEntry: CaptureHistoryEntry?

    var body: some View {
        List(entries, selection: $selectedEntry) { entry in
            HistoryListItemView(entry: entry)
                .tag(entry)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 300)
    }
}

/// Individual list item showing entry preview
struct HistoryListItemView: View {
    let entry: CaptureHistoryEntry

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Timestamp
            Text(entry.timestamp, formatter: dateFormatter)
                .font(.caption)
                .foregroundColor(.secondary)

            // Mode and destination
            HStack(spacing: 4) {
                Text(entry.modeName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(entry.destinationType)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(4)
            }

            // Input preview (first line)
            Text(entry.inputText.components(separatedBy: "\n").first ?? "")
                .font(.body)
                .lineLimit(1)
                .foregroundColor(.primary)

            // Output preview (first line)
            Text(entry.processedOutput.components(separatedBy: "\n").first ?? "")
                .font(.caption)
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Detail view showing full entry information
struct HistoryDetailView: View {
    let entry: CaptureHistoryEntry

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with metadata
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.timestamp, formatter: dateFormatter)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        // Mode
                        Label(entry.modeName, systemImage: "slider.horizontal.3")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(6)

                        // Provider (if available)
                        if let providerName = entry.providerName {
                            Label(providerName, systemImage: "cpu")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.purple.opacity(0.2))
                                .cornerRadius(6)
                        }

                        // Destination
                        Label(entry.destinationType, systemImage: "arrow.up.forward")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(6)
                    }
                }

                Divider()

                // Capture Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Captured Input")
                        .font(.headline)

                    ForEach(entry.actions) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: action.sourceIcon)
                                    .foregroundColor(.blue)
                                Text(action.sourceDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(action.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(action.text)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(6)
                        }
                    }
                }

                Divider()

                // Processed Output
                VStack(alignment: .leading, spacing: 8) {
                    Text("Processed Output")
                        .font(.headline)

                    Text(entry.processedOutput)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    let sampleActions = [
        CaptureAction(source: .selectedText, text: "Sample selected text"),
        CaptureAction(source: .recording, text: "This is a test recording transcription", audioFileURL: nil),
        CaptureAction(source: .clipboard, text: "Clipboard content here")
    ]

    let sampleEntry = CaptureHistoryEntry(
        actions: sampleActions,
        modeName: "Assistant",
        modeId: UUID(),
        providerName: "Apple Foundation Models",
        providerId: UUID(),
        processedOutput: "This is the processed output from the AI.\n\nIt contains multiple lines and paragraphs to demonstrate how the history detail view displays longer content.",
        destinationType: "Copy"
    )

    return HistoryView()
        .onAppear {
            CaptureHistory.shared.addEntry(sampleEntry)
        }
}
