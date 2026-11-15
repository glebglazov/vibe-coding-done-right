import SwiftUI

struct HistoryView: View {
    let history: any HistoryStore
    let historySync: SyncReconciler?
    let reprocessor: any ConversationReprocessor
    /// The entry the list opens on and marks: the one a Discard note's VIEW
    /// asked for.
    var focus: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var copiedConversationID: UUID?
    @State private var copyConfirmationTask: Task<Void, Never>?
    @State private var showClearAllConfirmation = false
    @State private var discardedInSheet: Conversation?

    private var theme: Theme { Theme.current(for: colorScheme) }
    private static let copyConfirmationDuration: Duration = .seconds(1.5)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showsFilter {
                    HistoryFilterChips(
                        filter: history.filter,
                        discardedCount: history.discardedCount,
                        theme: theme
                    ) { history.filter = $0 }
                }
                if history.conversations.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(theme.surfaceLowest)
            .navigationTitle("HISTORY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.onSurface)
                }
                ToolbarItem(placement: .principal) {
                    SyncIndicator(reconciler: historySync)
                }
                if !history.conversations.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear All", role: .destructive) {
                                showClearAllConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(theme.onSurface)
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
            .sheet(item: $discardedInSheet) { conversation in
                DiscardedConversationSheet(
                    conversation: conversation,
                    defaultChoice: reprocessor.defaultChoice(for: conversation),
                    onProcess: { reprocessor.process(conversation, with: $0) },
                    onCopy: { copy(conversation) },
                    onDelete: { history.removeConversation(id: conversation.id) }
                )
                .environment(\.theme, theme)
            }
            // The next visit starts from the whole list.
            .onDisappear { history.filter = .all }
        }
    }

    /// The chips stay while the Discarded filter is on, so an empty filtered
    /// list always has a way back to ALL.
    private var showsFilter: Bool {
        !history.conversations.isEmpty || history.filter == .discarded
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(theme.onSurfaceVariant)
            Text(history.filter == .discarded ? "NO DISCARDED RECORDINGS" : "NO HISTORY YET")
                .font(.system(size: 12, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(history.conversations) { conversation in
                    HistoryRow(
                        conversation: conversation,
                        theme: theme,
                        isCopied: copiedConversationID == conversation.id,
                        choiceInProgress: reprocessor.choiceInProgress(for: conversation.id),
                        failure: reprocessor.failure(for: conversation.id)
                    )
                    .id(conversation.id)
                    .listRowBackground(conversation.id == focus ? theme.surfaceHigh : theme.surfaceLowest)
                    .listRowSeparatorTint(theme.onSurfaceVariant.opacity(0.2))
                    .contentShape(Rectangle())
                    .onTapGesture { tap(conversation) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", role: .destructive) {
                            history.removeConversation(id: conversation.id)
                        }
                    }
                }
                if history.hasMorePages {
                    Color.clear
                        .frame(height: 1)
                        .listRowBackground(Color.clear)
                        .onAppear { history.loadNextPage() }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await historySync?.reconcile()
            }
            .onAppear {
                if let focus { proxy.scrollTo(focus, anchor: .center) }
            }
        }
    }

    /// A normal row copies. A Discarded Conversation has no output to copy
    /// yet, so its row opens the actions instead.
    private func tap(_ conversation: Conversation) {
        guard conversation.status.isDiscarded else {
            copy(conversation)
            return
        }
        guard reprocessor.choiceInProgress(for: conversation.id) == nil else { return }
        discardedInSheet = conversation
    }

    private func copy(_ conversation: Conversation) {
        UIPasteboard.general.string = conversation.copyableText
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copyConfirmationTask?.cancel()
        copiedConversationID = conversation.id
        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: Self.copyConfirmationDuration)
            guard !Task.isCancelled else { return }
            if copiedConversationID == conversation.id {
                copiedConversationID = nil
            }
        }
    }
}
