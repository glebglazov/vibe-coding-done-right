import SwiftUI

struct HistoryTabView: View {
    let history: TranscriptionHistory

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView(
                    "No Transcriptions Yet",
                    systemImage: "text.bubble",
                    description: Text("Your transcription history will appear here.")
                )
            } else {
                List(history.records) { record in
                    HistoryRowView(record: record)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All") {
                        history.clearAll()
                    }
                }
            }
        }
    }
}

private struct HistoryRowView: View {
    let record: TranscriptionRecord

    // MARK: - Constants
    private static let textLineLimit = 3
    /// Extra trailing padding on the plain copy button to align with the menu
    /// copy button, which has a system chevron taking up space to its right.
    private static let copyButtonTrailingPadding: CGFloat = 15

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.text)
                    .lineLimit(Self.textLineLimit)

                if let result = record.actionResult {
                    // Script entry: transcription is primary (the question),
                    // script output shown below with a subtle terminal icon
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(result)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(Self.textLineLimit)
                    }
                }

                HStack(spacing: 12) {
                    Label(record.modelName, systemImage: "cpu")
                    Label(record.formattedDuration, systemImage: "timer")
                    Label(
                        record.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                        systemImage: "clock"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if record.actionResult != nil {
                Menu {
                    Button("Copy Transcription") {
                        copyToClipboard(record.text)
                    }
                    Button("Copy Result") {
                        copyToClipboard(record.actionResult ?? "")
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .tint(.secondary)
                .fixedSize()
            } else {
                Button {
                    copyToClipboard(record.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .padding(.trailing, Self.copyButtonTrailingPadding)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Transcription") {
                copyToClipboard(record.text)
            }
            if let result = record.actionResult {
                Button("Copy Result") {
                    copyToClipboard(result)
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
