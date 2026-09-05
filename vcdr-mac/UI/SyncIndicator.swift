import SwiftUI

/// One dataset's Sync Pass, as a click target that asks for a fresh one.
///
/// Absent when sync is off: there is no reconciler to report on, and what the
/// tab shows is complete without one.
///
/// Two separate things are shown side by side: whether iCloud is carrying the
/// records at all, and how the last Sync Pass went. A pass runs against local
/// files while the user is signed out, so paused and working are both possible
/// at once.
struct SyncIndicator: View {
    let reconciler: SyncReconciler?

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
                    .foregroundStyle(reconciler.passState == .outstanding ? .orange : .secondary)
                }
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

    /// Availability only — the Last Sync Time is visible in the control
    /// itself rather than hiding in a tooltip.
    private func tooltip(for state: SyncReconciler.SyncState) -> String {
        switch state {
        case .idle: "iCloud is carrying these records — click to check now"
        case .paused(let reason): reason
        }
    }
}
