import Foundation
import OSLog

/// File-per-record Substitution store. Each entry lives in its own JSON file so
/// deletes can be modeled as append-only tombstones — letting cross-device
/// merges keep concurrent edits to *different* entries instead of last-writer-
/// wins on a shared blob.
///
/// Directory layout (under `Substitutions/`):
///   {uuid}.json          ← snapshot
///   {uuid}.deleted.json  ← tombstone event
///
/// Tombstone suppression: a snapshot is hidden when a tombstone exists whose
/// `deletedAt` is strictly greater than the snapshot's `lastUpdated`. A later
/// edit on another device (`lastUpdated` ≥ `deletedAt`) resurrects the entry.
@MainActor
@Observable
final class FileSubstitutionStore: SubstitutionStore {

    // MARK: - Constants

    private static let snapshotSuffix = ".json"
    private static let tombstoneSuffix = ".deleted.json"
    private static let substitutionsDirName = "Substitutions"
    private static let appGroupIdentifier = "group.glebglazov.vcdr-ios"
    private static let storageFolderName = "VCDR"

    // MARK: - State

    private(set) var substitutions: [Substitution] = []

    let substitutionsDir: URL
    // nonisolated(unsafe) — JSONEncoder/Decoder are immutable after init and
    // thread-safe for concurrent encode/decode. Captured by detached tasks
    // that perform disk I/O off MainActor.
    nonisolated(unsafe) private let encoder: JSONEncoder
    nonisolated(unsafe) private let decoder: JSONDecoder

    // MARK: - Init

    init(storageRoot: URL = FileSubstitutionStore.defaultStorageRoot) {
        self.substitutionsDir = storageRoot.appendingPathComponent(Self.substitutionsDirName)
        self.encoder = SubstitutionJSONCoders.makeEncoder()
        self.decoder = SubstitutionJSONCoders.makeDecoder()

        ensureDirectoryExists()
        reload()
    }

    // MARK: - SubstitutionStore

    func upsert(_ substitution: Substitution) {
        var entry = substitution
        entry.lastUpdated = Date()

        // Update in-memory state synchronously so the UI and the matcher reflect
        // the edit immediately; disk I/O is dispatched off MainActor below.
        substitutions.removeAll { $0.id == entry.id }
        substitutions.insert(entry, at: 0)

        let url = snapshotURL(id: entry.id)
        let encoder = self.encoder
        Task.detached(priority: .utility) {
            Self.writeSnapshotOffMain(entry, to: url, encoder: encoder)
        }
    }

    func delete(_ substitution: Substitution) {
        let now = Date()
        let id = substitution.id
        substitutions.removeAll { $0.id == id }

        let url = tombstoneURL(id: id)
        let encoder = self.encoder
        Task.detached(priority: .utility) {
            Self.writeTombstoneOffMain(id: id, deletedAt: now, url: url, encoder: encoder)
        }
    }

    func reload() {
        substitutions = Self.scanOffMain(substitutionsDir: substitutionsDir, decoder: decoder)
    }

    /// Async counterpart to `reload` that moves the directory scan and JSON
    /// decodes onto a utility-priority detached task. Safe to call from the
    /// MainActor without stalling the UI when snapshot files live in an iCloud
    /// ubiquity container where a read can block on placeholder materialization.
    func reloadAsync() async {
        let dir = substitutionsDir
        let decoder = self.decoder
        let loaded = await Task.detached(priority: .utility) {
            Self.scanOffMain(substitutionsDir: dir, decoder: decoder)
        }.value
        substitutions = loaded
    }

    // MARK: - Disk I/O

    /// Nonisolated so it can run inside `Task.detached` — callers precompute the
    /// destination URL on MainActor to avoid touching instance state here.
    nonisolated private static func writeSnapshotOffMain(
        _ substitution: Substitution,
        to url: URL,
        encoder: JSONEncoder
    ) {
        do {
            let data = try encoder.encode(substitution)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.substitutions.error("FileSubstitutionStore write snapshot failed: \(error)")
        }
    }

    nonisolated private static func writeTombstoneOffMain(
        id: UUID,
        deletedAt: Date,
        url: URL,
        encoder: JSONEncoder
    ) {
        let tombstone = SubstitutionTombstone(substitutionID: id, deletedAt: deletedAt)
        do {
            let data = try encoder.encode(tombstone)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.substitutions.error("FileSubstitutionStore write tombstone failed: \(error)")
        }
    }

    // MARK: - Scan

    /// Nonisolated disk scan used by both the synchronous `reload` (called from
    /// `init`) and the async refresh path (called from a detached task). Decodes
    /// every snapshot, then suppresses any whose entry was tombstoned later.
    nonisolated private static func scanOffMain(
        substitutionsDir: URL,
        decoder: JSONDecoder
    ) -> [Substitution] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: substitutionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var tombstones: [UUID: Date] = [:]
        var snapshots: [Substitution] = []

        for url in urls {
            let name = url.lastPathComponent
            // `.deleted.json` also ends in `.json`, so test the tombstone
            // suffix first to avoid decoding a tombstone as a snapshot.
            if name.hasSuffix(tombstoneSuffix) {
                guard let data = try? Data(contentsOf: url),
                      let tombstone = try? decoder.decode(SubstitutionTombstone.self, from: data) else { continue }
                if tombstones[tombstone.substitutionID].map({ tombstone.deletedAt > $0 }) ?? true {
                    tombstones[tombstone.substitutionID] = tombstone.deletedAt
                }
            } else if name.hasSuffix(snapshotSuffix) {
                guard let data = try? Data(contentsOf: url),
                      let substitution = try? decoder.decode(Substitution.self, from: data) else { continue }
                snapshots.append(substitution)
            }
        }

        let live = snapshots.filter { substitution in
            guard let deletedAt = tombstones[substitution.id] else { return true }
            // Delete wins only when strictly newer than the edit; a later edit
            // (lastUpdated ≥ deletedAt) resurrects the entry.
            return !(deletedAt > substitution.lastUpdated)
        }
        return live.sorted { $0.lastUpdated > $1.lastUpdated }
    }

    // MARK: - Filenames

    private func snapshotURL(id: UUID) -> URL {
        substitutionsDir.appendingPathComponent("\(id.uuidString)\(Self.snapshotSuffix)")
    }

    private func tombstoneURL(id: UUID) -> URL {
        substitutionsDir.appendingPathComponent("\(id.uuidString)\(Self.tombstoneSuffix)")
    }

    // MARK: - Filesystem

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: substitutionsDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Storage roots

    /// The root used when sync is disabled or the iCloud container is
    /// unavailable. On macOS: Application Support. On iOS: the App Group
    /// container (falling back to Application Support if the group is missing).
    /// Mirrors `FileHistoryStore.localStorageRoot` so both stores share one
    /// app-private `VCDR` parent directory.
    nonisolated static var localStorageRoot: URL {
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storageFolderName)
        #else
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return group.appendingPathComponent(storageFolderName)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(storageFolderName)
        #endif
    }

    nonisolated static var defaultStorageRoot: URL { localStorageRoot }
}
