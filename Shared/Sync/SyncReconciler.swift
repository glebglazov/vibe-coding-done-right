import Foundation
import OSLog

/// Brings the Record Files other devices wrote into a Local Store, in the
/// background, after launch.
///
/// Everything iCloud is here and nowhere else: resolving the ubiquity
/// container, watching it with `NSMetadataQuery`, materializing the
/// placeholders it hands back, resolving `NSFileVersion` siblings
/// last-writer-wins, and noticing that the user signed out. The store this
/// drives knows a database and a directory of files and nothing more, which is
/// what lets a later transport replace this one without touching the read path
/// (see `docs/adr/0010`).
///
/// One reconciler carries one dataset. Conversations and Substitutions differ
/// only in the answers `SyncedDataset` gives — which folder, which toggle —
/// so both travel through this same worker.
///
/// The sync toggle decides whether this exists at all. With it off nothing
/// here is constructed, the container is never resolved, and the app is a
/// complete local-only app.
@MainActor
@Observable
final class SyncReconciler {

    nonisolated static let containerIdentifier = "iCloud.glebglazov.vcdr"

    /// Whether iCloud is carrying the device's records, and why not when it
    /// is not. Reads never observe this: they answer from the Local Store
    /// whatever it says.
    enum SyncState: Equatable {
        case idle
        case paused(reason: String)
    }

    private(set) var syncState: SyncState = .idle

    private static let signedOutReason = "iCloud signed out"

    // MARK: - State

    private let store: any RecordFileSyncedStore
    private let dataset: SyncedDataset

    /// The directory of Record Files this device syncs through. Nil until
    /// `start` has resolved it — every pass is a no-op before that.
    private var directory: URL?

    private let metadataQuery = NSMetadataQuery()
    private var observerTokens: [NSObjectProtocol] = []

    /// De-duplicates overlapping passes. A pull-to-refresh arriving while a
    /// query-driven pass is still merging would otherwise scan the same
    /// directory twice and publish the same list twice.
    private var passInFlight = false

    // MARK: - Init

    init(store: any RecordFileSyncedStore, dataset: SyncedDataset) {
        self.store = store
        self.dataset = dataset
    }

    /// Starts syncing a dataset in the background when its toggle allows it,
    /// and hands back the reconciler that owns it.
    ///
    /// With sync off there is no reconciler and the container is never
    /// resolved: the store keeps its Record Files in the app's own storage,
    /// and reads — which never came from iCloud — are unchanged.
    static func startIfEnabled(
        store: any RecordFileSyncedStore,
        dataset: SyncedDataset,
        defaults: UserDefaults
    ) -> SyncReconciler? {
        guard dataset.syncEnabled(defaults: defaults) else {
            Task { await store.syncRecordFiles(in: dataset.localDirectory) }
            return nil
        }
        let reconciler = SyncReconciler(store: store, dataset: dataset)
        Task { await reconciler.start() }
        return reconciler
    }

    // NB: no deinit. NotificationCenter observer tokens are held in stored
    // properties; they deallocate with `self`. Every closure captures
    // `[weak self]`, so any notification that fires after deallocation no-ops.
    // The `NSMetadataQuery` instance is likewise only retained by this class.

    // MARK: - Lifecycle

    /// Resolves the container, brings what it holds in, and then watches it
    /// for more. Every blocking hop — provisioning the container, reading the
    /// account token, the merge itself — stays on a GCD thread (ADR-0005), and
    /// nothing on a read path waits for any of it.
    func start() async {
        let dataset = self.dataset
        let resolved = await withBlockingTask(qos: .utility) {
            Self.resolveRecordFiles(for: dataset)
        }
        directory = resolved.directory
        syncState = resolved.hasAccount ? .idle : .paused(reason: Self.signedOutReason)
        observeAccountStateChanges()
        startWatchingContainer()
        await reconcile()
    }

    /// One pass: materialize whatever iCloud has not downloaded, resolve any
    /// conflict siblings, then let the store merge the directory in and export
    /// what it still owes. Idempotent, so the watcher runs one whenever the
    /// container stirs and the user can ask for one at any time.
    func reconcile() async {
        guard let directory, !passInFlight else { return }
        passInFlight = true
        defer { passInFlight = false }

        let pending = collectPendingItems(under: directory)
        await withBlockingTask(qos: .utility) { Self.materialize(pending) }
        await store.syncRecordFiles(in: directory)
    }

    // MARK: - Container

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

    private struct Resolved: Sendable {
        let directory: URL
        let hasAccount: Bool
    }

    /// Where this device's Record Files live, and whether iCloud is usable —
    /// one blocking hop, because both answers come from the iCloud daemon.
    ///
    /// Without a container the app's own storage stands in, so a device that
    /// cannot reach iCloud still keeps its records as files and starts
    /// carrying them the moment iCloud comes back.
    nonisolated private static func resolveRecordFiles(for dataset: SyncedDataset) -> Resolved {
        guard let root = resolveStorageRoot() else {
            Logger.sync.info("\(dataset.name) sync: no container, using local record files")
            return Resolved(directory: dataset.localDirectory, hasAccount: false)
        }
        let directory = root.appendingPathComponent(dataset.containerSubdirectory)
        RecordFileMigrator.adoptLocalRecordFiles(
            from: dataset.localDirectory,
            into: directory
        )
        return Resolved(
            directory: directory,
            hasAccount: FileManager.default.ubiquityIdentityToken != nil
        )
    }

    // MARK: - Watcher

    private func startWatchingContainer() {
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Everything under the dataset's folder, record or tombstone.
        metadataQuery.predicate = NSPredicate(
            format: "%K LIKE[c] %@",
            NSMetadataItemFSNameKey,
            "*.json"
        )
        metadataQuery.valueListAttributes = [
            NSMetadataItemURLKey,
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemHasUnresolvedConflictsKey
        ]

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observerTokens.append(center.addObserver(
                forName: name,
                object: metadataQuery, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconcile() }
            })
        }

        metadataQuery.enableUpdates()
        metadataQuery.start()
    }

    /// What a pass has to ask the iCloud daemon for before the files can be
    /// read: bytes that are not on this device yet, and records that came back
    /// from two devices at once.
    private struct PendingItems: Sendable {
        let toDownload: [URL]
        let conflicts: [URL]
        let resolveConflicts: @Sendable ([URL]) -> Void
    }

    /// Reads the current `NSMetadataQuery` results on the main actor —
    /// `NSMetadataItem` attribute access must happen on the query's queue —
    /// and packages the work into a Sendable value a GCD thread can act on.
    private func collectPendingItems(under directory: URL) -> PendingItems {
        let items = (metadataQuery.results as? [NSMetadataItem]) ?? []
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
            resolveConflicts: dataset.resolveConflicts
        )
    }

    /// Asks iCloud for the bytes behind the placeholders and collapses the
    /// conflict siblings onto one winner. Both operations block on iCloud
    /// daemon IPC and must not run on the main actor.
    nonisolated private static func materialize(_ pending: PendingItems) {
        for url in pending.toDownload {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        if !pending.conflicts.isEmpty {
            pending.resolveConflicts(pending.conflicts)
        }
    }

    // MARK: - Account state

    private func observeAccountStateChanges() {
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccountState() }
        })
    }

    private func refreshAccountState() {
        if FileManager.default.ubiquityIdentityToken != nil {
            syncState = .idle
        } else {
            syncState = .paused(reason: Self.signedOutReason)
        }
    }
}
