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
    private static let turnDividerVPadding: CGFloat = 4

    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .top) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    // Header: turn count + continue arrow
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

                    // Render all turns using shared ConversationTurnView
                    let turns = conversationTurns
                    let showLabels = shouldShowLabels(turns: turns)
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        ConversationTurnView(
                            turn: turn,
                            showLabels: showLabels,
                            modeName: conversation.hadExternalProcessing ? conversation.modeName : nil,
                            isProcessing: false,
                            showCopyButton: false
                        )

                        if index < turns.count - 1 {
                            Divider()
                                .padding(.vertical, Self.turnDividerVPadding)
                        }
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

            // Copy latest output (or input if no output) button
            Button {
                copyToClipboard(conversation.latestOutput ?? conversation.previewText)
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
                copyToClipboard(conversation.latestOutput ?? conversation.previewText)
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    // MARK: - Helpers

    private var conversationTurns: [ConversationTurn] {
        conversation.turns
    }

    /// Same logic as CaptureViewModel.showConversationLabels
    private func shouldShowLabels(turns: [ConversationTurn]) -> Bool {
        if turns.count > 1 { return true }
        guard let turn = turns.first else { return false }
        if !turn.captures.isEmpty { return true }
        return turn.output != nil
    }

    private func copyToClipboard(_ text: String) {
        ClipboardHelper.writeString(text)
        CopiedFeedback.trigger { showCopied = $0 }
    }
}
