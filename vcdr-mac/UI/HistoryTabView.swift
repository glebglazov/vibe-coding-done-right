import SwiftUI

struct HistoryTabView: View {
    let history: any HistoryStore
    let historySync: SyncReconciler?
    let settings: AppSettings
    let reprocessor: any ConversationReprocessor
    @State private var showClearAllConfirmation = false

    var body: some View {
        Group {
            if history.conversations.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(history.conversations) { conversation in
                        row(for: conversation)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                history.removeConversation(id: conversation.id)
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
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: filter) {
                    Text("All").tag(HistoryFilter.all)
                    Text("Discarded · \(history.discardedCount)").tag(HistoryFilter.discarded)
                }
                .pickerStyle(.segmented)
                .fixedSize()
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

    private var filter: Binding<HistoryFilter> {
        Binding(get: { history.filter }, set: { history.filter = $0 })
    }

    @ViewBuilder
    private var emptyView: some View {
        switch history.filter {
        case .all:
            ContentUnavailableView(
                "No History Yet",
                systemImage: "text.bubble",
                description: Text("Your history will appear here.")
            )
        case .discarded:
            ContentUnavailableView(
                "No Discarded Entries",
                systemImage: "xmark.circle",
                description: Text("A recording you discard with its hotkey appears here.")
            )
        }
    }

    @ViewBuilder
    private func row(for conversation: Conversation) -> some View {
        if case .discarded(let choice) = conversation.status {
            DiscardedConversationRowView(
                conversation: conversation,
                choice: choice,
                modes: settings.modes,
                isProcessing: reprocessor.processingIDs.contains(conversation.id),
                failure: reprocessor.failures[conversation.id],
                onProcess: { mode in Task { await reprocessor.process(conversation, with: mode) } },
                onDelete: { history.removeConversation(id: conversation.id) }
            )
        } else {
            ConversationRowView(
                conversation: conversation,
                onDelete: { history.removeConversation(id: conversation.id) }
            )
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
