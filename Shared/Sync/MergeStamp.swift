import Foundation

/// The Merge Stamp a delete carries.
///
/// A delete is decided against the edit it buries by comparing stamps, and the
/// stamps round-trip through the Record Files at millisecond resolution — so a
/// delete issued in the same millisecond as the edit before it reads back as a
/// tie, and a tie leaves the record alive. Deleting is always causally after
/// the edit it saw, so the stamp moves forward one storage tick when the clock
/// has not.
nonisolated enum MergeStamp {

    /// One millisecond: what the JSON coders keep of a `Date`.
    static let storageResolution: TimeInterval = 0.001

    static func deleting(after lastUpdated: Date, now: Date = Date()) -> Date {
        max(now, lastUpdated + storageResolution)
    }
}
