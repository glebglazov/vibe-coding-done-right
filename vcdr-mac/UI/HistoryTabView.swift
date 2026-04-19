import SwiftUI

struct HistoryTabView: View {
    let history: any HistoryStore
    let settings: AppSettings

    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear {
            (history as? UbiquityHistoryStore)?.checkForPendingUpdates()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                (history as? UbiquityHistoryStore)?.checkForPendingUpdates()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SyncIndicator(history: history)
            }
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

private struct SyncIndicator: View {
    let history: any HistoryStore

    var body: some View {
        if let sync = history as? UbiquityHistoryStore {
            Button {
                sync.refresh()
            } label: {
                icon(for: sync.syncState)
            }
            .buttonStyle(.plain)
            .help(tooltip(for: sync.syncState))
        }
    }

    @ViewBuilder
    private func icon(for state: UbiquityHistoryStore.SyncState) -> some View {
        Group {
            switch state {
            case .idle:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(.secondary)
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.secondary)
            case .pendingUpdates:
                Image(systemName: "icloud.and.arrow.down.fill")
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .nonRepeating)
            case .paused:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.orange)
            }
        }
        .symbolRenderingMode(.monochrome)
    }

    private func tooltip(for state: UbiquityHistoryStore.SyncState) -> String {
        switch state {
        case .idle: "Synced"
        case .syncing: "Syncing…"
        case .pendingUpdates: "New entries available — click to load"
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
            Text(conversation.lastUpdated.formatted(
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
