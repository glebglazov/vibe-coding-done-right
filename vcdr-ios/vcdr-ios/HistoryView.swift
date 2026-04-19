import SwiftUI

struct HistoryView: View {
    let history: any HistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var copiedConversationID: UUID?
    @State private var copyConfirmationTask: Task<Void, Never>?

    private var theme: Theme { Theme.current(for: colorScheme) }
    private static let copyConfirmationDuration: Duration = .seconds(1.5)

    var body: some View {
        NavigationStack {
            Group {
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
                if !history.conversations.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { history.clearAll() }
                            .foregroundStyle(theme.onSurface)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(theme.onSurfaceVariant)
            Text("NO HISTORY YET")
                .font(.system(size: 12, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(history.conversations) { conversation in
                HistoryRow(
                    conversation: conversation,
                    theme: theme,
                    isCopied: copiedConversationID == conversation.id
                )
                .listRowBackground(theme.surfaceLowest)
                .listRowSeparatorTint(theme.onSurfaceVariant.opacity(0.2))
                .contentShape(Rectangle())
                .onTapGesture { copy(conversation) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", role: .destructive) {
                        history.removeConversation(conversation)
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

private struct HistoryRow: View {
    let conversation: Conversation
    let theme: Theme
    let isCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let label = conversation.label, conversation.hadExternalProcessing {
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
                if isCopied {
                    Text("COPIED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(theme.primary)
                        .transition(.opacity)
                }
            }
            Text(conversation.previewText)
                .font(.system(size: 14))
                .foregroundStyle(theme.onSurface)
                .lineLimit(4)
            if conversation.hadExternalProcessing {
                Text(conversation.inputText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(3)
            }
            Text(conversation.lastUpdated.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.system(size: 11, weight: .medium))
            .tracking(1)
            .foregroundStyle(theme.onSurfaceVariant)
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.15), value: isCopied)
        .contextMenu {
            Button("Copy") {
                UIPasteboard.general.string = conversation.copyableText
            }
        }
    }
}
