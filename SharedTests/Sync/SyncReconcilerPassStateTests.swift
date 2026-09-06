import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// What the sync control is told before, during and after the first Sync Pass.
/// A device that has not been checked must not present itself as a checked
/// one, and a pass that comes back Outstanding must still have the previous
/// launch's Last Sync Time to show. One source tree compiled into both
/// `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("SyncReconciler pass state")
struct SyncReconcilerPassStateTests {

    /// Stands in for the Local Store: no database, no files, just the
    /// Outstanding Work the pass should see it report.
    private final class StubStore: RecordFileSyncedStore {
        let outstanding: OutstandingWork

        init(outstanding: OutstandingWork) {
            self.outstanding = outstanding
        }

        func syncRecordFiles(in directory: URL) async -> OutstandingWork {
            outstanding
        }
    }

    /// A dataset of this test's own. Its record-file directory is a name and
    /// nothing more: the stub store answers every pass, the migrator skips a
    /// source that does not exist, and a folder that was never renamed is left
    /// alone — so no test here puts one on disk.
    private func makeDataset() -> SyncedDataset {
        SyncedDataset(
            name: "test",
            folder: RecordFilesFolder("test"),
            syncEnabledDefaultsKey: "test.sync.enabled",
            syncEnabledDefault: true,
            lastSyncTimeDefaultsKey: "test.sync.lastSyncTime",
            resolveConflicts: { _ in }
        )
    }

    /// A container of this test's own: a folder handed to the watcher stands in
    /// for the ubiquity container, so a pass here never provisions the real one.
    private func makeWatcher() -> ContainerWatcher {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-container-\(UUID().uuidString)", isDirectory: true)
        return ContainerWatcher(storageRoot: { root })
    }

    private func makeDefaults(lastSyncTime: Date?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "vcdr-sync-\(UUID().uuidString)")!
        if let lastSyncTime {
            defaults.set(lastSyncTime, forKey: "test.sync.lastSyncTime")
        }
        return defaults
    }

    @Test("an unchecked device reports working, restored Last Sync Time and all")
    func workingBeforeFirstPass() {
        let previousLaunch = Date(timeIntervalSince1970: 1_700_000_000)
        let reconciler = SyncReconciler(
            store: StubStore(outstanding: .none),
            dataset: makeDataset(),
            defaults: makeDefaults(lastSyncTime: previousLaunch),
            watcher: makeWatcher()
        )

        #expect(reconciler.passState == .working)
        #expect(reconciler.lastSyncTime == previousLaunch)
    }

    @Test("a settled first pass moves the control off working")
    func settledFirstPass() async {
        let before = Date()
        let reconciler = SyncReconciler(
            store: StubStore(outstanding: .none),
            dataset: makeDataset(),
            defaults: makeDefaults(lastSyncTime: nil),
            watcher: makeWatcher()
        )

        await reconciler.start()

        #expect(reconciler.passState == .settled)
        #expect((reconciler.lastSyncTime ?? .distantPast) >= before)
    }

    @Test("an outstanding first pass keeps the previous launch's Last Sync Time")
    func outstandingFirstPass() async {
        let previousLaunch = Date(timeIntervalSince1970: 1_700_000_000)
        let reconciler = SyncReconciler(
            store: StubStore(outstanding: OutstandingWork(rowsAwaitingExport: 1)),
            dataset: makeDataset(),
            defaults: makeDefaults(lastSyncTime: previousLaunch),
            watcher: makeWatcher()
        )

        await reconciler.start()

        #expect(reconciler.passState == .outstanding)
        #expect(reconciler.lastSyncTime == previousLaunch)
    }
}
