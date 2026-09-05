import SwiftUI

/// How a Sync Pass reads to the user: working while one is in flight, the Last
/// Sync Time when the last one settled, and that same older time behind a
/// "catching up" note when it did not.
///
/// Both history lists show the same words. Font and colour come from the
/// control the platform wraps this in.
struct SyncStatusLabel: View {
    let passState: SyncReconciler.PassState
    let lastSyncTime: Date?

    var body: some View {
        HStack(spacing: 4) {
            switch passState {
            case .working:
                ProgressView()
                    .controlSize(.small)
                Text("syncing…")
            case .settled:
                syncedAgo
            case .outstanding:
                Text("catching up ·")
                syncedAgo
            }
        }
    }

    /// Relative and self-refreshing: SwiftUI re-renders a `.relative` date as
    /// the minutes pass, so the list needs no timer to keep it true.
    @ViewBuilder
    private var syncedAgo: some View {
        if let lastSyncTime {
            Text("synced")
            Text(lastSyncTime, style: .relative)
            Text("ago")
        } else {
            Text("not synced yet")
        }
    }
}
