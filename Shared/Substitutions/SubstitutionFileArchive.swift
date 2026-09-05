import Foundation
import OSLog

/// A directory of per-entry Substitution files — the shape the app has always
/// stored Substitutions in, and now the transport it syncs them through:
///
///   {uuid}.json          ← snapshot
///   {uuid}.deleted.json  ← tombstone event
///
/// One file per entry is what lets a delete be an append-only tombstone
/// instead of an edit to a shared blob, so two devices editing *different*
/// Substitutions both keep their edits (ADR-0004).
///
/// Unlike a conversation, a Substitution carries its own `lastUpdated` and its
/// tombstone its own `deletedAt`, so precedence is decided on what the files
/// say rather than on their mtimes. Both are decoded here and the ranking is
/// left to the Local Store.
nonisolated struct SubstitutionFileArchive: Sendable {

    /// A delete some device made, as the tombstone file that records it.
    struct Tombstone: Equatable, Sendable {
        let id: UUID
        let deletedAt: Date
    }

    /// What one read of the directory found: every entry it holds, and every
    /// delete some device has made.
    struct Scan: Sendable {
        let substitutions: [Substitution]
        let tombstones: [Tombstone]
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Reading

    /// Reads and decodes the whole directory. There is no window on this: the
    /// list is about ten entries, and a Substitution left behind is visibly
    /// wrong text in the next transcript.
    func scan() -> Scan {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Scan(substitutions: [], tombstones: [])
        }

        let decoder = SubstitutionJSONCoders.makeDecoder()
        var substitutions: [Substitution] = []
        var tombstones: [UUID: Date] = [:]

        for url in urls {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else { continue }
            // `.deleted.json` also ends in `.json`, so test the tombstone
            // suffix first to avoid decoding a tombstone as a snapshot.
            if name.hasSuffix(Self.tombstoneSuffix) {
                guard let tombstone = try? decoder.decode(SubstitutionTombstone.self, from: data) else { continue }
                if tombstones[tombstone.substitutionID].map({ tombstone.deletedAt > $0 }) ?? true {
                    tombstones[tombstone.substitutionID] = tombstone.deletedAt
                }
            } else if name.hasSuffix(Self.snapshotSuffix) {
                guard let substitution = try? decoder.decode(Substitution.self, from: data) else { continue }
                substitutions.append(substitution)
            }
        }

        return Scan(
            substitutions: substitutions,
            tombstones: tombstones.map { Tombstone(id: $0.key, deletedAt: $0.value) }
        )
    }

    // MARK: - Writing

    /// - Returns: whether the file is now in the directory. A refused write
    ///   leaves the entry owing its file, which is what makes the next drain
    ///   retry it instead of dropping the Substitution.
    func writeSnapshot(_ substitution: Substitution, encoder: JSONEncoder) -> Bool {
        return write(
            try? encoder.encode(substitution),
            named: "\(substitution.id.uuidString)\(Self.snapshotSuffix)"
        )
    }

    /// - Returns: whether the tombstone is now in the directory, on the same
    ///   terms as `writeSnapshot`.
    func writeTombstone(id: UUID, deletedAt: Date, encoder: JSONEncoder) -> Bool {
        let tombstone = SubstitutionTombstone(substitutionID: id, deletedAt: deletedAt)
        return write(
            try? encoder.encode(tombstone),
            named: "\(id.uuidString)\(Self.tombstoneSuffix)"
        )
    }

    private func write(_ data: Data?, named filename: String) -> Bool {
        guard let data else {
            Logger.substitutions.error("Substitution file \(filename) could not be encoded")
            return false
        }
        do {
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return true
        } catch {
            Logger.substitutions.error("Substitution file write failed for \(filename): \(error)")
            return false
        }
    }

    // MARK: - Filenames

    private static let snapshotSuffix = ".json"
    private static let tombstoneSuffix = ".deleted.json"
}
