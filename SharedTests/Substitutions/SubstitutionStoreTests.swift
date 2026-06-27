import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Exercises the per-entry Substitution storage layer against the local
/// `FileSubstitutionStore`: round-trip load/save/update/delete, last-writer-wins
/// conflict resolution on `lastUpdated`, and delete-vs-edit tombstone
/// precedence. One source tree compiled into both `vcdr-macTests` and
/// `vcdr-iosTests`.
@MainActor
@Suite("SubstitutionStore")
struct SubstitutionStoreTests {

    // MARK: - Fixtures

    /// A fresh, isolated storage root per call so tests never share on-disk state.
    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-subs-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func substitutionsDir(in root: URL) -> URL {
        root.appendingPathComponent("Substitutions", isDirectory: true)
    }

    /// Writes a snapshot fixture directly to disk (bypassing the async write
    /// path) so scan/suppression behavior can be asserted deterministically.
    private func writeSnapshot(_ substitution: Substitution, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try SubstitutionJSONCoders.makeEncoder().encode(substitution)
        try data.write(to: dir.appendingPathComponent("\(substitution.id.uuidString).json"))
    }

    private func writeTombstone(id: UUID, deletedAt: Date, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tombstone = SubstitutionTombstone(substitutionID: id, deletedAt: deletedAt)
        let data = try SubstitutionJSONCoders.makeEncoder().encode(tombstone)
        try data.write(to: dir.appendingPathComponent("\(id.uuidString).deleted.json"))
    }

    /// Polls a condition off the async write path with a generous timeout.
    @discardableResult
    private func eventually(
        timeoutMS: Int = 3000,
        stepMS: Int = 10,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let steps = max(1, timeoutMS / stepMS)
        for _ in 0..<steps {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(stepMS))
        }
        return condition()
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Save + load

    @Test("save then load: a fresh store reads the persisted entry")
    func saveAndLoad() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSubstitutionStore(storageRoot: root)
        let id = UUID()
        store.upsert(Substitution(id: id, triggerPhrase: "oh my zsh", replacement: "Oh My Zsh"))

        // In-memory state updates synchronously.
        #expect(store.substitutions.count == 1)
        #expect(store.substitutions.first?.triggerPhrase == "oh my zsh")

        let snapshot = substitutionsDir(in: root).appendingPathComponent("\(id.uuidString).json")
        #expect(await eventually { self.fileExists(snapshot) })

        // A brand-new store at the same root loads the persisted entry from disk.
        let reloaded = FileSubstitutionStore(storageRoot: root)
        #expect(reloaded.substitutions.count == 1)
        let loaded = try #require(reloaded.substitutions.first)
        #expect(loaded.id == id)
        #expect(loaded.triggerPhrase == "oh my zsh")
        #expect(loaded.replacement == "Oh My Zsh")
        #expect(loaded.isEnabled)
    }

    // MARK: - Update

    @Test("update: re-upserting the same id rewrites its single file")
    func update() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSubstitutionStore(storageRoot: root)
        let id = UUID()
        store.upsert(Substitution(id: id, triggerPhrase: "ip", replacement: "IP address"))
        let snapshot = substitutionsDir(in: root).appendingPathComponent("\(id.uuidString).json")
        #expect(await eventually { self.fileExists(snapshot) })

        store.upsert(Substitution(id: id, triggerPhrase: "ip", replacement: "Internet Protocol", isEnabled: false))
        #expect(store.substitutions.count == 1)
        #expect(await eventually {
            let reloaded = FileSubstitutionStore(storageRoot: root)
            return reloaded.substitutions.first?.replacement == "Internet Protocol"
        })

        // Still exactly one file per entry, and the update stuck.
        let reloaded = FileSubstitutionStore(storageRoot: root)
        #expect(reloaded.substitutions.count == 1)
        let loaded = try #require(reloaded.substitutions.first)
        #expect(loaded.replacement == "Internet Protocol")
        #expect(loaded.isEnabled == false)

        let files = try FileManager.default.contentsOfDirectory(
            at: substitutionsDir(in: root), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".json") }
        #expect(files.count == 1)
    }

    // MARK: - Delete

    @Test("delete: writes a tombstone, keeps the snapshot, suppresses the entry")
    func delete() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSubstitutionStore(storageRoot: root)
        let sub = Substitution(triggerPhrase: "secret", replacement: "REDACTED")
        store.upsert(sub)
        let dir = substitutionsDir(in: root)
        let snapshot = dir.appendingPathComponent("\(sub.id.uuidString).json")
        #expect(await eventually { self.fileExists(snapshot) })

        store.delete(sub)
        #expect(store.substitutions.isEmpty)

        let tombstone = dir.appendingPathComponent("\(sub.id.uuidString).deleted.json")
        #expect(await eventually { self.fileExists(tombstone) })
        // Snapshot file is intentionally left on disk so unsynced peers merge.
        #expect(fileExists(snapshot))

        // The tombstone carries the deleted id and a recent timestamp.
        let data = try Data(contentsOf: tombstone)
        let decoded = try SubstitutionJSONCoders.makeDecoder().decode(SubstitutionTombstone.self, from: data)
        #expect(decoded.substitutionID == sub.id)

        // A fresh store does not resurrect the deleted entry.
        let reloaded = FileSubstitutionStore(storageRoot: root)
        #expect(reloaded.substitutions.isEmpty)
    }

    @Test("concurrent edits to different entries both survive a delete of a third")
    func perEntryGranularity() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSubstitutionStore(storageRoot: root)
        let a = Substitution(triggerPhrase: "a", replacement: "alpha")
        let b = Substitution(triggerPhrase: "b", replacement: "bravo")
        let c = Substitution(triggerPhrase: "c", replacement: "charlie")
        store.upsert(a)
        store.upsert(b)
        store.upsert(c)
        let dir = substitutionsDir(in: root)
        #expect(await eventually {
            self.fileExists(dir.appendingPathComponent("\(c.id.uuidString).json"))
        })

        store.delete(b)
        #expect(await eventually {
            self.fileExists(dir.appendingPathComponent("\(b.id.uuidString).deleted.json"))
        })

        let reloaded = FileSubstitutionStore(storageRoot: root)
        let ids = Set(reloaded.substitutions.map(\.id))
        #expect(ids == [a.id, c.id])
    }

    // MARK: - LWW conflict resolution

    @Test("LWW: the sibling with the greatest lastUpdated wins")
    func lwwPicksGreatestLastUpdated() throws {
        let id = UUID()
        let older = Substitution(
            id: id, triggerPhrase: "t", replacement: "OLD",
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        let newer = Substitution(
            id: id, triggerPhrase: "t", replacement: "NEW",
            lastUpdated: Date(timeIntervalSince1970: 2_000)
        )

        let winner = try #require(SubstitutionConflictResolver.winner(among: [older, newer]))
        #expect(winner.replacement == "NEW")
        // Order-independent.
        let winnerReversed = try #require(SubstitutionConflictResolver.winner(among: [newer, older]))
        #expect(winnerReversed.replacement == "NEW")
    }

    @Test("LWW: winner decoded from sibling files written by the local store coders")
    func lwwOverDecodedSiblings() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = substitutionsDir(in: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = UUID()
        let encoder = SubstitutionJSONCoders.makeEncoder()
        let decoder = SubstitutionJSONCoders.makeDecoder()
        let siblings = [
            Substitution(id: id, triggerPhrase: "t", replacement: "v1", lastUpdated: Date(timeIntervalSince1970: 10)),
            Substitution(id: id, triggerPhrase: "t", replacement: "v2", lastUpdated: Date(timeIntervalSince1970: 30)),
            Substitution(id: id, triggerPhrase: "t", replacement: "v3", lastUpdated: Date(timeIntervalSince1970: 20)),
        ]
        var decoded: [Substitution] = []
        for (offset, sibling) in siblings.enumerated() {
            let url = dir.appendingPathComponent("sibling-\(offset).json")
            try encoder.encode(sibling).write(to: url)
            decoded.append(try decoder.decode(Substitution.self, from: Data(contentsOf: url)))
        }

        let winner = try #require(SubstitutionConflictResolver.winner(among: decoded))
        #expect(winner.replacement == "v2")
        #expect(winner.lastUpdated == Date(timeIntervalSince1970: 30))
    }

    // MARK: - Delete-vs-edit tombstone precedence

    @Test("tombstone precedence: deletedAt > lastUpdated suppresses the entry")
    func deleteWinsWhenNewer() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = substitutionsDir(in: root)

        let id = UUID()
        try writeSnapshot(
            Substitution(id: id, triggerPhrase: "t", replacement: "edit", lastUpdated: Date(timeIntervalSince1970: 100)),
            into: dir
        )
        try writeTombstone(id: id, deletedAt: Date(timeIntervalSince1970: 200), into: dir)

        let store = FileSubstitutionStore(storageRoot: root)
        #expect(store.substitutions.isEmpty)
    }

    @Test("tombstone precedence: a later edit (lastUpdated > deletedAt) resurrects the entry")
    func editWinsWhenNewer() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = substitutionsDir(in: root)

        let id = UUID()
        try writeTombstone(id: id, deletedAt: Date(timeIntervalSince1970: 100), into: dir)
        try writeSnapshot(
            Substitution(id: id, triggerPhrase: "t", replacement: "re-added", lastUpdated: Date(timeIntervalSince1970: 200)),
            into: dir
        )

        let store = FileSubstitutionStore(storageRoot: root)
        #expect(store.substitutions.count == 1)
        #expect(store.substitutions.first?.replacement == "re-added")
    }

    @Test("tombstone precedence: equal timestamps keep the entry (delete wins only when strictly newer)")
    func equalTimestampsKeepEntry() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = substitutionsDir(in: root)

        let id = UUID()
        let when = Date(timeIntervalSince1970: 500)
        try writeSnapshot(
            Substitution(id: id, triggerPhrase: "t", replacement: "kept", lastUpdated: when),
            into: dir
        )
        try writeTombstone(id: id, deletedAt: when, into: dir)

        let store = FileSubstitutionStore(storageRoot: root)
        #expect(store.substitutions.count == 1)
    }

    // MARK: - Factory

    @Test("factory falls back to the local store when no ubiquity root is available")
    func factoryFallsBackToLocal() {
        let defaults = ephemeralDefaults()
        let store = SubstitutionStoreFactory.make(defaults: defaults, ubiquityRoot: nil)
        #expect(store is FileSubstitutionStore)
    }

    @Test("factory uses the local store when sync is disabled, even with a ubiquity root")
    func factoryRespectsDisabledSync() {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: SubstitutionStoreFactory.syncEnabledDefaultsKey)
        let store = SubstitutionStoreFactory.make(defaults: defaults, ubiquityRoot: makeTempRoot())
        #expect(store is FileSubstitutionStore)
    }

    @Test("factory returns the ubiquity-backed store when sync is on and a root is available")
    func factoryReturnsUbiquityWhenAvailable() {
        let defaults = ephemeralDefaults()
        let store = SubstitutionStoreFactory.make(defaults: defaults, ubiquityRoot: makeTempRoot())
        #expect(store is UbiquitySubstitutionStore)
    }

    @Test("ubiquity container identifier is the existing one — no new entitlement")
    func reusesExistingContainerIdentifier() {
        #expect(UbiquitySubstitutionStore.containerIdentifier == "iCloud.glebglazov.vcdr")
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "test.substitutions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
