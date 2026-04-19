import Foundation

/// iCloud Drive-backed history store. Composes over `FileHistoryStore`,
/// pointing it at the ubiquity container's `Documents/VCDR` directory.
///
/// Background sync is handled by the OS iCloud daemon. This store layers on:
///   * `NSMetadataQuery` watcher — picks up remote changes and triggers
///     placeholder downloads + UI refresh.
///   * LWW conflict resolution — when concurrent edits produce `NSFileVersion`
///     siblings, the one with the latest `Conversation.lastUpdated` wins.
///   * Account-state observation — surfaces `.paused` when the user signs
///     out of iCloud mid-session.
///
/// Construction fails (`init?` returns nil) when the ubiquity container is
/// unavailable — iCloud signed out, entitlement missing, or capability not
/// yet provisioned. Callers fall back to a local-only `FileHistoryStore`.
@MainActor
@Observable
final class UbiquityHistoryStore: HistoryStore {

    nonisolated static let containerIdentifier = "iCloud.glebglazov.vcdr"

    /// Resolves the root of the ubiquity container's `Documents/VCDR` folder,
    /// or nil if iCloud is unavailable to the process right now.
    ///
    /// `Documents/` is required for the folder to appear in Files.app and
    /// Finder's iCloud Drive view — a useful debug escape hatch.
    nonisolated static func resolveStorageRoot() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        return container.appendingPathComponent("Documents/VCDR")
    }

    // MARK: - Sync state

    enum SyncState: Equatable {
        case idle
        /// New records were detected in the ubiquity container but not yet
        /// merged into `conversations` — user must tap the sync indicator or
        /// pull-to-refresh to apply them.
        case pendingUpdates
        case paused(reason: String)
    }

    private(set) var syncState: SyncState = .idle

    // MARK: - Composition

    /// All disk I/O, indexing, pagination, and record/tombstone writes flow
    /// through the inner store. We only layer on sync-aware behavior.
    let inner: FileHistoryStore

    private let metadataQuery: NSMetadataQuery
    private var queryObserverTokens: [NSObjectProtocol] = []
    private var accountObserverToken: (any NSObjectProtocol)?

    /// Tracks whether the metadata query has delivered its initial
    /// `DidFinishGathering` event. Before that, updates are applied
    /// immediately so the first view of the page isn't empty. After that,
    /// updates surface as `.pendingUpdates` and wait for the user.
    private var hasGatheredInitialSet = false

    // MARK: - Init

    init?(storageRoot: URL? = UbiquityHistoryStore.resolveStorageRoot()) {
        guard let storageRoot else { return nil }
        self.inner = FileHistoryStore(storageRoot: storageRoot)
        self.metadataQuery = NSMetadataQuery()
        startWatchingContainer()
        observeAccountStateChanges()
        refreshAccountState()
    }

    // NB: no deinit. NotificationCenter observer tokens are held in stored
    // properties; they deallocate with `self`. Every closure captures
    // `[weak self]`, so any notification that fires after deallocation no-ops.
    // The `NSMetadataQuery` instance is likewise only retained by this class.

    // MARK: - HistoryStore (delegation)

    var conversations: [Conversation] { inner.conversations }
    var latestConversation: Conversation? { inner.latestConversation }
    var hasMorePages: Bool { inner.hasMorePages }

    func record(
        conversationID: UUID,
        inputSegments: [InputSegment],
        output: String?,
        label: String?
    ) {
        inner.record(
            conversationID: conversationID,
            inputSegments: inputSegments,
            output: output,
            label: label
        )
    }

    func removeConversation(_ conversation: Conversation) {
        inner.removeConversation(conversation)
    }

    func clearAll() { inner.clearAll() }

    func loadNextPage() { inner.loadNextPage() }

    /// Applies any pending remote updates: kicks off placeholder downloads,
    /// resolves conflict siblings, then rescans the filesystem and reloads
    /// the first page into `conversations`. Called when the user taps the
    /// sync indicator or pulls-to-refresh.
    func refresh() {
        processMetadataResults()
        inner.rebuildIndexAndReloadFirstPage()
        // If the account-state observer has paused us, don't clobber that.
        if case .paused = syncState { return }
        syncState = .idle
    }

    // MARK: - NSMetadataQuery watcher

    private func startWatchingContainer() {
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Everything under the conversations folder, snapshot or tombstone.
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

        let nc = NotificationCenter.default
        queryObserverTokens.append(nc.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInitialGathering() }
        })
        queryObserverTokens.append(nc.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: metadataQuery, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleIncrementalUpdate() }
        })

        metadataQuery.enableUpdates()
        metadataQuery.start()
    }

    /// First-load path: apply immediately so the history page isn't empty
    /// on the user's first visit after enabling sync.
    private func handleInitialGathering() {
        processMetadataResults()
        inner.rebuildIndexAndReloadFirstPage()
        hasGatheredInitialSet = true
        if case .paused = syncState { return }
        syncState = .idle
    }

    /// Subsequent-update path: detect newly-added filenames and surface them
    /// as `.pendingUpdates` so the user decides when to apply. Downloads
    /// are still kicked off in the background so the bytes are ready by
    /// the time the user taps refresh.
    private func handleIncrementalUpdate() {
        guard hasGatheredInitialSet else {
            // Shouldn't happen — DidUpdate fires after DidFinishGathering —
            // but defensively: treat as initial.
            handleInitialGathering()
            return
        }

        let newFilenames = processMetadataResults()

        // Account state always wins.
        if case .paused = syncState { return }
        if !newFilenames.isEmpty {
            syncState = .pendingUpdates
        }
    }

    /// Walks the current `NSMetadataQuery` results: kicks off placeholder
    /// downloads for missing files, dispatches conflict resolution to a
    /// detached task (iCloud reads can block), and returns any filenames
    /// not yet tracked by the inner index. `NSMetadataItem` access must
    /// happen on the main thread, so the collection work stays here.
    @discardableResult
    private func processMetadataResults() -> [String] {
        let conversationsPath = inner.conversationsDir.path
        let items = (metadataQuery.results as? [NSMetadataItem]) ?? []
        let known = inner.indexedFilenames
        var conflictURLs: [URL] = []
        var newFilenames: [String] = []

        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.path.contains(conversationsPath) else { continue }

            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            if let hasConflict = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               hasConflict {
                conflictURLs.append(url)
            }
            let filename = url.lastPathComponent
            if !known.contains(filename) {
                newFilenames.append(filename)
            }
        }

        if !conflictURLs.isEmpty {
            HistoryConflictResolver.resolve(urls: conflictURLs)
        }
        return newFilenames
    }

    // MARK: - Account-state observation

    private func observeAccountStateChanges() {
        accountObserverToken = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccountState() }
        }
    }

    private func refreshAccountState() {
        if FileManager.default.ubiquityIdentityToken != nil {
            if case .paused = syncState { syncState = .idle }
        } else {
            syncState = .paused(reason: "iCloud signed out")
        }
    }
}
