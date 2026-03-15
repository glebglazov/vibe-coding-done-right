import SwiftUI

struct HistoryTabView: View {
    let history: TranscriptionHistory
    let settings: AppSettings
    let onOpenConversation: (Conversation) -> Void

    var body: some View {
        Group {
            if history.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet",
                    systemImage: "text.bubble",
                    description: Text("Your conversation history will appear here.")
                )
            } else {
                List {
                    ForEach(history.conversations) { conversation in
                        ConversationRowView(
                            conversation: conversation,
                            canContinue: canContinue(conversation),
                            onOpen: { onOpenConversation(conversation) },
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

    private func canContinue(_ conversation: Conversation) -> Bool {
        conversation.canContinue(modes: settings.modes)
    }
}

private struct ConversationRowView: View {
    let conversation: Conversation
    let canContinue: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    // MARK: - Constants
    private static let previewLineLimit = 3
    private static let selectionPreviewLineLimit = 2

    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    // Turn count
                    HStack(spacing: 6) {
                        if conversation.turns.count > 1 {
                            Text("\(conversation.turns.count) turns")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if canContinue {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Preview text (first turn's input)
                    Text(conversation.previewText)
                        .lineLimit(Self.previewLineLimit)

                    // Captured context preview (first turn's first capture only)
                    if let firstCapture = conversation.turns.first?.captures.first {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "text.quote")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(firstCapture.text)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(Self.selectionPreviewLineLimit)
                        }
                    }

                    // If there are multiple turns, show last turn's output as secondary preview
                    if conversation.turns.count > 1 {
                        Text(conversation.latestOutput)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(Self.previewLineLimit)
                    }

                    // Timestamp
                    Text(conversation.lastUpdated.formatted(
                        .dateTime.month(.abbreviated).day().hour().minute()
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Copy latest output button — outside the row button to prevent press animation bleed
            Button {
                copyToClipboard(conversation.latestOutput)
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .tint(showCopied ? .green : .secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if canContinue {
                Button("Continue Conversation") {
                    onOpen()
                }
            } else {
                Button("View Conversation") {
                    onOpen()
                }
            }

            Button("Copy Latest Output") {
                copyToClipboard(conversation.latestOutput)
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        ClipboardHelper.writeString(text)
        CopiedFeedback.trigger($showCopied)
    }
}
