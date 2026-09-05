import Foundation

/// Everything a Sync Pass ended without settling. A pass that leaves none of it
/// is a Settled Pass, and only such a pass moves a dataset's Last Sync Time:
/// asking iCloud for a file is not the same as having it (see `docs/adr/0012`).
///
/// The parts come from either side of the store/reconciler boundary. The
/// reconciler sees what the container still owes this device; the store sees
/// the rows of its database that still owe the container.
nonisolated struct OutstandingWork: Equatable, Sendable {

    /// Record Files whose bytes this device does not hold yet.
    var undownloadedRecordFiles = 0

    /// Records two devices wrote at once, not yet collapsed onto one winner.
    var unresolvedConflicts = 0

    /// Rows in the Local Store still owing their Record File.
    var rowsAwaitingExport = 0

    static let none = OutstandingWork()

    var isSettled: Bool {
        undownloadedRecordFiles == 0 && unresolvedConflicts == 0 && rowsAwaitingExport == 0
    }
}
