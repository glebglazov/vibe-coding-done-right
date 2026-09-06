import Foundation

/// Hears about the ubiquity container stirring, routes each change to the
/// Synced Datasets whose folder holds it, and reads out what the container
/// holds that this device cannot yet use.
///
/// `NSMetadataQuery` is the only way to learn that another device wrote a
/// Record File — the container's directory lists the file long before its bytes
/// arrive — and its items may only be read on the queue it runs on, which is
/// this actor's. Every iCloud-shaped detail lives here so a Sync Pass is left
/// with plain values it can act on off the main actor, and so whoever builds
/// the reconcilers learns a type name and nothing more about iCloud.
///
/// One watcher serves every dataset. A query covers the whole container and
/// matches on file name alone, so a second one would carry the same items and
/// report the same changes; what separates the datasets is which folder each
/// is watching.
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

    /// One Synced Dataset's folder, and the Sync Pass a change inside it starts.
    private struct Route {
        let folder: ContainerFolder
        let startPass: @MainActor () -> Void
    }

    nonisolated static let containerIdentifier = "iCloud.glebglazov.vcdr"

    /// Whether iCloud is carrying this device's records right now.
    ///
    /// Blocking: the answer comes from the iCloud daemon (ADR-0005).
    nonisolated static var hasAccount: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private let query = NSMetadataQuery()
    private var observerTokens: [NSObjectProtocol] = []
    private var routes: [Route] = []

    private let storageRootSource: @Sendable () -> URL?
    private var storageRootResolution: Task<URL?, Never>?

    /// A watcher over the app's own ubiquity container. Tests hand in a folder
    /// of their own instead, which is what keeps them off iCloud.
    init(storageRoot: @escaping @Sendable () -> URL? = { ContainerWatcher.resolveStorageRoot() }) {
        storageRootSource = storageRoot
    }

    // NB: no deinit. NotificationCenter observer tokens are held in a stored
    // property and deallocate with `self`, and the query is retained by nothing
    // else, so a notification firing after deallocation reaches no one.

    // MARK: - The container

    /// The folder every dataset's folder sits under, or nil when iCloud is
    /// unreachable to the process right now.
    ///
    /// Resolved once and shared: resolving provisions the container, which
    /// takes seconds on the first launch after install, and each dataset
    /// asking for itself would pay that again.
    func storageRoot() async -> URL? {
        if let storageRootResolution { return await storageRootResolution.value }
        let resolution = Task { [storageRootSource] in
            await withBlockingTask(qos: .utility, storageRootSource)
        }
        storageRootResolution = resolution
        return await resolution.value
    }

    /// Resolves the root of the ubiquity container's `Documents/VCDR` folder,
    /// or nil if iCloud is unavailable to the process right now.
    ///
    /// `Documents/` is required for the folder to appear in Files.app and
    /// Finder's iCloud Drive view — a useful debug escape hatch.
    ///
    /// Blocking: resolving the container provisions it, which takes seconds on
    /// the first launch after install.
    nonisolated static func resolveStorageRoot() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        return container.appendingPathComponent("Documents/VCDR")
    }

    // MARK: - Watching

    /// Starts a Sync Pass through `startPass` whenever the container stirs
    /// under `directory` — once when the first gathering finishes, and then
    /// for every update that touches a Record File the folder holds.
    ///
    /// A change outside the folder never reaches it, which is what keeps one
    /// dataset's arriving Record File from moving the other dataset's control.
    func watch(_ directory: URL, startPass: @escaping @MainActor () -> Void) {
        routes.append(Route(folder: ContainerFolder(directory), startPass: startPass))
        startQueryIfNeeded()
    }

    private func startQueryIfNeeded() {
        guard !query.isStarted else { return }

        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Every dataset's Record Files and tombstones, in one query. The folder
        // each dataset occupies is what a route matches on afterwards.
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
        observerTokens.append(center.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query, queue: .main
        ) { [weak self] _ in
            // The first gathering is every dataset's first sight of the
            // container, so it reaches all of them.
            Task { @MainActor in self?.startEveryPass() }
        })
        observerTokens.append(center.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query, queue: .main
        ) { [weak self] notification in
            // Read here, on the queue the query runs on, because that is the
            // only place its items may be touched. What crosses to the actor
            // is plain URLs.
            let changed = Self.changedURLs(in: notification)
            Task { @MainActor in self?.startPasses(for: changed) }
        })

        query.enableUpdates()
        query.start()
    }

    private func startEveryPass() {
        for route in routes { route.startPass() }
    }

    private func startPasses(for changed: [URL]) {
        for route in routes where changed.contains(where: route.folder.holds) {
            route.startPass()
        }
    }

    /// What an update says moved — added, changed and removed alike, since any
    /// of the three is a reason for the folder's dataset to run a pass.
    nonisolated private static func changedURLs(in notification: Notification) -> [URL] {
        let keys = [
            NSMetadataQueryUpdateAddedItemsKey,
            NSMetadataQueryUpdateChangedItemsKey,
            NSMetadataQueryUpdateRemovedItemsKey
        ]
        return keys.flatMap { key in
            let items = notification.userInfo?[key] as? [NSMetadataItem] ?? []
            return items.compactMap { $0.value(forAttribute: NSMetadataItemURLKey) as? URL }
        }
    }

    // MARK: - Reading

    /// What the container currently owes this device under one directory,
    /// packaged as a Sendable value a GCD thread can act on.
    func pendingItems(
        under directory: URL,
        resolveConflicts: @escaping @Sendable ([URL]) -> Void
    ) -> PendingItems {
        let folder = ContainerFolder(directory)
        var toDownload: [URL] = []
        var conflicts: [URL] = []

        // Read one result at a time, with updates held off: bridging `results`
        // into an array copies the whole container on the drawing thread before
        // the walk even begins, and an update landing mid-walk would move the
        // set out from under it.
        query.disableUpdates()
        defer { query.enableUpdates() }

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  folder.holds(url) else { continue }

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
