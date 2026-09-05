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
        .overlay(alignment: .topTrailing) {
            SyncIndicator(reconciler: historySync)
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
        .navigationTitle("History")
        .toolbar {
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

/// Absent when sync is off: there is no reconciler to report on, and the
/// history the list shows is complete without one.
private struct SyncIndicator: View {
    let reconciler: SyncReconciler?

    var body: some View {
        if let reconciler {
            Button {
                Task { await reconciler.reconcile() }
            } label: {
                icon(for: reconciler.syncState)
            }
            .buttonStyle(.plain)
            .help(tooltip(for: reconciler.syncState))
        }
    }

    @ViewBuilder
    private func icon(for state: SyncReconciler.SyncState) -> some View {
        Group {
            switch state {
            case .idle:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(.secondary)
            case .paused:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.orange)
            }
        }
        .symbolRenderingMode(.monochrome)
    }

    private func tooltip(for state: SyncReconciler.SyncState) -> String {
        switch state {
        case .idle: "Synced — click to check now"
        case .paused(let reason): reason
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
