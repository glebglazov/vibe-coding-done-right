import Foundation

/// Hears about the ubiquity container stirring, and reads out what it holds
/// that this device cannot yet use.
///
/// `NSMetadataQuery` is the only way to learn that another device wrote a
/// Record File — the container's directory lists the file long before its bytes
/// arrive — and its items may only be read on the queue it runs on, which is
/// this actor's. Every iCloud-shaped detail of that lives here so a Sync Pass
/// is left with plain values it can act on off the main actor.
@MainActor
final class ContainerWatcher {

    /// What a pass has to ask the iCloud daemon for before the files can be
    /// read: bytes that are not on this device yet, and records that came back
    /// from two devices at once.
    struct PendingItems: Sendable {
        let toDownload: [URL]
        let conflicts: [URL]
        let resolveConflicts: @Sendable ([URL]) -> Void
    }

    private let query = NSMetadataQuery()
    private var observerTokens: [NSObjectProtocol] = []

    // NB: no deinit. NotificationCenter observer tokens are held in a stored
    // property and deallocate with `self`, and the query is retained by nothing
    // else, so a notification firing after deallocation reaches no one.

    /// Starts watching, and calls `onChange` every time the container stirs —
    /// once when the first gathering finishes, then on every update.
    func start(onChange: @escaping @MainActor () -> Void) {
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Everything under the dataset's folder, record or tombstone.
        query.predicate = NSPredicate(
            format: "%K LIKE[c] %@",
            NSMetadataItemFSNameKey,
            "*.json"
        )
        query.valueListAttributes = [
            NSMetadataItemURLKey,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemHasUnresolvedConflictsKey
        ]

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observerTokens.append(center.addObserver(
                forName: name,
                object: query, queue: .main
            ) { _ in
                Task { @MainActor in onChange() }
            })
        }

        query.enableUpdates()
        query.start()
    }

    /// What the container currently owes this device under one directory,
    /// packaged as a Sendable value a GCD thread can act on.
    func pendingItems(
        under directory: URL,
        resolveConflicts: @escaping @Sendable ([URL]) -> Void
    ) -> PendingItems {
        let items = (query.results as? [NSMetadataItem]) ?? []
        var toDownload: [URL] = []
        var conflicts: [URL] = []

        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.path.contains(directory.path) else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                toDownload.append(url)
            }
            if let hasConflict = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               hasConflict {
                conflicts.append(url)
            }
        }

        return PendingItems(
            toDownload: toDownload,
            conflicts: conflicts,
            resolveConflicts: resolveConflicts
        )
    }

    /// Asks iCloud for the bytes behind the placeholders and collapses the
    /// conflict siblings onto one winner. Both operations block on iCloud
    /// daemon IPC and must not run on the main actor.
    nonisolated static func materialize(_ pending: PendingItems) {
        for url in pending.toDownload {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        if !pending.conflicts.isEmpty {
            pending.resolveConflicts(pending.conflicts)
        }
    }
}
