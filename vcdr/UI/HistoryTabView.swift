import SwiftUI

struct HistoryTabView: View {
    let history: TranscriptionHistory
    let settings: AppSettings

    var body: some View {
        Group {
            if history.conversations.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "text.bubble",
                    description: Text("Your history will appear here.")
                )
            } else {
                List {
                    ForEach(history.conversations) { conversation in
                        ConversationRowView(
                            conversation: conversation,
                            onDelete: { history.removeConversation(conversation) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                history.removeConversation(conversation)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !history.conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All") {
                        history.clearAll()
                    }
                }
            }
        }
    }
}

private struct ConversationRowView: View {
    let conversation: Conversation
    let onDelete: () -> Void

    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                let turn = DisplayedTurn(
                    inputSegments: conversation.inputSegments,
                    output: conversation.output
                )
                let showLabels = conversation.hadExternalProcessing
                    || conversation.inputSegments.contains(where: { $0.capture != nil })

                DisplayedTurnView(
                    turn: turn,
                    showLabels: showLabels,
                    modeName: conversation.hadExternalProcessing ? conversation.modeName : nil,
                    isProcessing: false,
                    showCopyButton: false
                )

                // Timestamp
                Text(conversation.lastUpdated.formatted(
                    .dateTime.month(.abbreviated).day().hour().minute()
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Copy button
            Button {
                copyToClipboard(conversation.copyableText)
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .tint(showCopied ? .green : .secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") {
                copyToClipboard(conversation.copyableText)
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        ClipboardHelper.writeString(text)
        CopiedFeedback.trigger { showCopied = $0 }
    }
}
