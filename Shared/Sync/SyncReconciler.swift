import Foundation
import OSLog

/// Brings the Record Files other devices wrote into a Local Store, in the
/// background, after launch.
///
/// Everything iCloud is here and in the `ContainerWatcher` this drives, and
/// nowhere else: resolving the ubiquity container, hearing it stir,
/// materializing the placeholders it hands back, resolving `NSFileVersion`
/// siblings last-writer-wins, and noticing that the user signed out. The store
/// this drives knows a database and a directory of files and nothing more,
/// which is what lets a later transport replace this one without touching the
/// read path (see `docs/adr/0010`).
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

    /// Whether a Sync Pass is running, and how the last one that finished
    /// ended. Separate from `syncState` because the two are not exclusive: a
    /// pass still runs against local files while iCloud is signed out.
    enum PassState: Equatable {
        case working
        case settled
        case outstanding
    }

    private(set) var passState: PassState = .settled

    /// When this dataset last had a Settled Pass on this device. Restored from
    /// defaults at construction, so a cold launch says how current the device
    /// is before it has had a chance to check.
    private(set) var lastSyncTime: Date?

    private static let signedOutReason = "iCloud signed out"

    /// How long the working state stays visible once it appears. A cold launch
    /// against a stirring container produces a burst of passes, which would
    /// otherwise strobe the control instead of reading as one stretch of work.
    private static let workingStateFloor: Duration = .seconds(1)

    // MARK: - State

    private let store: any RecordFileSyncedStore
    private let dataset: SyncedDataset
    private let defaults: UserDefaults

    /// The directory of Record Files this device syncs through. Nil until
    /// `start` has resolved it — every pass is a no-op before that.
    private var directory: URL?

    private let watcher = ContainerWatcher()
    private var observerTokens: [NSObjectProtocol] = []

    /// Keeps passes from overlapping. A pull-to-refresh arriving while a
    /// query-driven pass is still merging would otherwise scan the same
    /// directory at the same time and publish the same list twice; it waits
    /// its turn as `passQueued` instead.
    private var passInFlight = false

    /// An ask that arrived mid-pass. The running pass read the directory
    /// before whatever prompted the ask, so it owes one more pass rather than
    /// the ask being dropped.
    private var passQueued = false

    // MARK: - Init

    init(store: any RecordFileSyncedStore, dataset: SyncedDataset, defaults: UserDefaults) {
        self.store = store
        self.dataset = dataset
        self.defaults = defaults
        self.lastSyncTime = dataset.lastSyncTime(defaults: defaults)
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
        let reconciler = SyncReconciler(store: store, dataset: dataset, defaults: defaults)
        Task { await reconciler.start() }
        return reconciler
    }

    // NB: no deinit. NotificationCenter observer tokens are held in a stored
    // property; they deallocate with `self`. Every closure captures
    // `[weak self]`, so any notification that fires after deallocation no-ops.

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
        watcher.start { [weak self] in
            Task { await self?.reconcile() }
        }
        await reconcile()
    }

    /// Runs Sync Passes until nothing more is asked of it, then reports how
    /// the last one ended. Idempotent, so the watcher runs one whenever the
    /// container stirs and the user can ask for one at any time.
    ///
    /// An ask arriving mid-pass extends this stretch by one pass instead of
    /// being dropped: the running pass read the directory before the change
    /// that prompted the ask.
    func reconcile() async {
        guard let directory else { return }
        guard !passInFlight else {
            passQueued = true
            return
        }
        passInFlight = true
        passState = .working
        let startedWorking = ContinuousClock.now
        defer { passInFlight = false }

        var outstanding: OutstandingWork
        var finishedAt: Date
        repeat {
            passQueued = false
            outstanding = await runPass(in: directory)
            finishedAt = Date()
            // Held inside the loop, so an ask arriving while the working state
            // is still on its floor extends the stretch rather than being lost.
            await holdWorkingState(since: startedWorking)
        } while passQueued

        if outstanding.isSettled {
            recordSettledPass(at: finishedAt)
        }
        passState = outstanding.isSettled ? .settled : .outstanding
    }

    /// One pass: materialize whatever iCloud has not downloaded, resolve any
    /// conflict siblings, then let the store merge the directory in and export
    /// what it still owes — and add up what it all left outstanding.
    private func runPass(in directory: URL) async -> OutstandingWork {
        let pending = watcher.pendingItems(
            under: directory,
            resolveConflicts: dataset.resolveConflicts
        )
        await withBlockingTask(qos: .utility) { ContainerWatcher.materialize(pending) }
        var outstanding = await store.syncRecordFiles(in: directory)
        // Counted as the pass found them, not as it leaves them:
        // `startDownloadingUbiquitousItem` only asks, and the bytes arrive over
        // the following minutes, each landing driving a further pass.
        outstanding.undownloadedRecordFiles = pending.toDownload.count
        outstanding.unresolvedConflicts = pending.conflicts.count
        if !outstanding.isSettled {
            Logger.sync.info("""
                \(self.dataset.name) sync: pass unsettled — \
                \(outstanding.undownloadedRecordFiles) undownloaded, \
                \(outstanding.unresolvedConflicts) conflicted, \
                \(outstanding.rowsAwaitingExport) awaiting export
                """)
        }
        return outstanding
    }

    /// Holds the working state for its floor, so a pass that returns in
    /// milliseconds still reads as work having happened.
    private func holdWorkingState(since startedWorking: ContinuousClock.Instant) async {
        let elapsed = ContinuousClock.now - startedWorking
        guard elapsed < Self.workingStateFloor else { return }
        try? await Task.sleep(for: Self.workingStateFloor - elapsed)
    }

    private func recordSettledPass(at time: Date) {
        lastSyncTime = time
        dataset.recordLastSyncTime(time, defaults: defaults)
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
