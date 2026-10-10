import SwiftUI

struct HistoryTabView: View {
    let history: any HistoryStore
    let historySync: SyncReconciler?
    let settings: AppSettings
    @State private var showClearAllConfirmation = false

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
            ToolbarItem(placement: .status) {
                SyncIndicator(reconciler: historySync)
            }
            if !history.conversations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Clear All", role: .destructive) {
                            showClearAllConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all transcriptions. This cannot be undone.")
        }
    }
}

private struct ConversationRowView: View {
    let conversation: Conversation
    let onDelete: () -> Void

    var body: some View {
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
                modeName: conversation.hadExternalProcessing ? conversation.label : nil,
                isProcessing: false,
                showCopyButton: true
            )

            // Timestamp
            Text(conversation.capturedAt.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") {
                ClipboardHelper.writeString(conversation.copyableText)
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
}
