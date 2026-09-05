import SwiftUI

/// How a Sync Pass reads to the user: working while one is in flight, the Last
/// Sync Time when the last one settled, and that same older time behind a
/// "catching up" note when it did not.
///
/// Both platforms show the same words, on the history list and on the
/// Substitutions screen alike. Font and colour come from the control the
/// platform wraps this in.
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

    /// The Last Sync Time in words, refreshed on the cadence its own band
    /// needs — once when the first minute is up, then a minute, an hour, a
    /// day — so a settled control sits still instead of counting.
    @ViewBuilder
    private var syncedAgo: some View {
        if let lastSyncTime {
            TimelineView(LastSyncSchedule(lastSyncTime: lastSyncTime)) { context in
                Text("synced \(LastSyncPhrase.of(lastSyncTime, at: context.date).words)")
            }
        } else {
            Text("not synced yet")
        }
    }
}

/// Wakes the label exactly when the phrase it is showing could have changed,
/// which the phrase itself answers.
private struct LastSyncSchedule: TimelineSchedule {
    let lastSyncTime: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        sequence(first: startDate) { shownAt in
            shownAt.addingTimeInterval(LastSyncPhrase.of(lastSyncTime, at: shownAt).staysTrueFor)
        }
    }
}
