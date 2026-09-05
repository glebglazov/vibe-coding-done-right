import SwiftUI

/// One dataset's Sync Pass, as a tap target that asks for a fresh one.
///
/// Absent when sync is off: there is no reconciler to report on, and what the
/// screen shows is complete without one.
///
/// Two separate things are shown side by side: whether iCloud is carrying the
/// records at all, and how the last Sync Pass went. A pass runs against local
/// files while the user is signed out, so paused and working are both possible
/// at once.
struct SyncIndicator: View {
    let reconciler: SyncReconciler?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: Theme { Theme.current(for: colorScheme) }

    var body: some View {
        if let reconciler {
            Button {
                Task { await reconciler.reconcile() }
            } label: {
                HStack(spacing: 6) {
                    icon(for: reconciler.syncState)
                    SyncStatusLabel(
                        passState: reconciler.passState,
                        lastSyncTime: reconciler.lastSyncTime
                    )
                    .font(.caption)
                    .foregroundStyle(color(for: reconciler.passState))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func color(for state: SyncReconciler.PassState) -> Color {
        state == .outstanding ? .orange : theme.onSurfaceVariant
    }

    @ViewBuilder
    private func icon(for state: SyncReconciler.SyncState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(theme.onSurfaceVariant)
        case .paused:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        }
    }
}
