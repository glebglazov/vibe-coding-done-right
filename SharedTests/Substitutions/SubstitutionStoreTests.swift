import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Drives the Substitution Local Store through the path the app uses: a
/// database opened from disk, the record files linked behind it, then reads and
/// writes going through the `SubstitutionStore` protocol. One source tree
/// compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("SubstitutionStore")
struct SubstitutionStoreTests {

    // MARK: - Fixtures

    /// A fresh, isolated storage root per call so tests never share on-disk
    /// state — neither the database file nor the record files.
    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-subs-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recordFilesDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Substitutions", isDirectory: true)
    }

    /// A store over its own database. Two devices are two of these over one
    /// directory of record files.
    private func makeStore(root: URL) throws -> LocalSubstitutionStore {
        LocalSubstitutionStore(
            snapshot: try LocalSubstitutionStore.loadSnapshot(
                fileURL: root.appendingPathComponent("substitutions.sqlite3")
            )
        )
    }

    /// Writes a snapshot the way a peer device would have left it.
    private func writeRecordFile(_ substitution: Substitution, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SubstitutionJSONCoders.makeEncoder().encode(substitution)
        try data.write(to: directory.appendingPathComponent("\(substitution.id.uuidString).json"))
    }

    private func writeTombstoneFile(id: UUID, deletedAt: Date, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstone = SubstitutionTombstone(substitutionID: id, deletedAt: deletedAt)
        let data = try SubstitutionJSONCoders.makeEncoder().encode(tombstone)
        try data.write(to: directory.appendingPathComponent("\(id.uuidString).deleted.json"))
    }

    /// Every file in a directory with its bytes and mtime — what proves the
    /// merge left the record files exactly as it found them.
    private func inventory(of directory: URL) -> [String: (Data, Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var inventory: [String: (Data, Date)] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate else { continue }
            inventory[url.lastPathComponent] = (data, modifiedAt)
        }
        return inventory
    }

    private func filenames(in directory: URL) -> Set<String> {
        Set(inventory(of: directory).keys)
    }

    /// Polls off the detached export path with a generous timeout.
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

    // MARK: - Import

    @Test("Reads the record files in, suppressing tombstoned entries and leaving every file untouched")
    func readsRecordFilesIn() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)

        let kept = Substitution(triggerPhrase: "oh my zsh", replacement: "Oh My Zsh")
        let deleted = Substitution(
            triggerPhrase: "secret",
            replacement: "REDACTED",
            lastUpdated: Date(timeIntervalSince1970: 100)
        )
        try writeRecordFile(kept, into: directory)
        try writeRecordFile(deleted, into: directory)
        try writeTombstoneFile(id: deleted.id, deletedAt: Date(timeIntervalSince1970: 200), into: directory)

        let before = inventory(of: directory)

        let store = try makeStore(root: root)
        #expect(store.substitutions.isEmpty, "the database is empty until the record files are linked")

        await store.syncRecordFiles(in: directory)

        #expect(store.substitutions.map(\.id) == [kept.id])
        #expect(store.substitutions.first?.replacement == "Oh My Zsh")

        // The record files are the rollback path: the merge only reads them.
        let after = inventory(of: directory)
        #expect(after.count == before.count)
        for (name, snapshot) in before {
            let current = after[name]
            #expect(current?.0 == snapshot.0, "\(name) was rewritten")
            #expect(current?.1 == snapshot.1, "\(name) was touched")
        }

        // Relaunch: matching and the screen answer from the database alone,
        // with no directory linked at all, and a second pass over the same
        // directory changes nothing.
        let relaunched = try makeStore(root: root)
        #expect(relaunched.substitutions.map(\.id) == [kept.id])
        await relaunched.syncRecordFiles(in: directory)
        #expect(relaunched.substitutions.count == 1)
        #expect(filenames(in: directory) == Set(before.keys))
    }

    // MARK: - Another device

    @Test("An entry another device wrote arrives here, and a delete on either removes it on both")
    func entriesTravelBetweenDevices() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)
        let thisDevice = try makeStore(root: makeTempRoot())
        let otherDevice = try makeStore(root: makeTempRoot())
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)

        let fromOther = Substitution(triggerPhrase: "ip", replacement: "IP address")
        otherDevice.upsert(fromOther)
        await otherDevice.syncRecordFiles(in: directory)

        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.substitutions.map(\.id) == [fromOther.id])

        // An edit there reaches here too, over the entry it already holds.
        var edited = try #require(otherDevice.substitutions.first)
        edited.replacement = "Internet Protocol"
        otherDevice.upsert(edited)
        await otherDevice.syncRecordFiles(in: directory)
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.substitutions.map(\.replacement) == ["Internet Protocol"])

        // The other device deletes it; this one stops showing it, and keeps it
        // gone however many passes follow.
        otherDevice.delete(try #require(otherDevice.substitutions.first))
        await otherDevice.syncRecordFiles(in: directory)

        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.substitutions.isEmpty)
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.substitutions.isEmpty, "a later pass resurrected the deleted entry")

        // A delete made here reaches the other device the same way.
        let fromHere = Substitution(triggerPhrase: "vcdr", replacement: "VCDR")
        thisDevice.upsert(fromHere)
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)
        #expect(otherDevice.substitutions.map(\.id) == [fromHere.id])

        thisDevice.delete(try #require(thisDevice.substitutions.first))
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.substitutions.isEmpty, "the pass that exported the delete undid it")
        await otherDevice.syncRecordFiles(in: directory)
        #expect(otherDevice.substitutions.isEmpty)
    }

    // MARK: - Convergence

    @Test("Two entries with one Replacement become one, the older surviving, and a removed phrase stays removed")
    func entriesWithOneReplacementConverge() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)
        let phone = try makeStore(root: makeTempRoot())
        let mac = try makeStore(root: makeTempRoot())

        // Both offline: the phone files the address first, the Mac files it
        // again later under a phrase of its own — and drops the phrase the
        // phone is still showing.
        let filedFirst = Substitution(
            triggerPhrases: ["gleb at gmail"],
            replacement: "gleb@example.com",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        phone.upsert(filedFirst)

        var filedSecond = Substitution(
            triggerPhrases: ["glep at gmail", "gleb at gmail"],
            replacement: "gleb@example.com",
            createdAt: Date(timeIntervalSince1970: 2_000),
            lastUpdated: Date(timeIntervalSince1970: 2_000)
        )
        let dropped = try #require(filedSecond.livePhrases.first { $0.text == "gleb at gmail" })
        filedSecond.removePhrase(dropped.id, at: Date(timeIntervalSince1970: 3_000))
        mac.upsert(filedSecond)

        await phone.syncRecordFiles(in: directory)
        await mac.syncRecordFiles(in: directory)
        await phone.syncRecordFiles(in: directory)

        for device in [phone, mac] {
            #expect(device.substitutions.map(\.id) == [filedFirst.id], "the older entry did not survive")
            #expect(device.substitutions.first?.triggerPhrases == ["glep at gmail"])
        }
        #expect(filenames(in: directory).contains("\(filedSecond.id.uuidString).deleted.json"))

        // Settled: another pass on either device finds nothing left to merge.
        await mac.syncRecordFiles(in: directory)
        await phone.syncRecordFiles(in: directory)
        #expect(mac.substitutions.map(\.id) == [filedFirst.id])
        #expect(phone.substitutions.first?.triggerPhrases == ["glep at gmail"])
    }

    @Test("Both devices pick the same survivor without seeing each other's answer")
    func bothDevicesPickTheSameSurvivor() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let filedFirst = Substitution(
            triggerPhrases: ["gleb at gmail"],
            replacement: "gleb@example.com",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        let filedSecond = Substitution(
            phrases: [TriggerPhrase(text: "glep at gmail", addedAt: Date(timeIntervalSince1970: 2_000))],
            replacement: "gleb@example.com",
            createdAt: Date(timeIntervalSince1970: 2_000),
            lastUpdated: Date(timeIntervalSince1970: 2_000)
        )

        // One directory each, holding the same two entries: neither device can
        // see what the other decides, so only the entries themselves can say.
        var answers: [(id: UUID, phrases: [String])] = []
        for _ in 0..<2 {
            let deviceRoot = makeTempRoot()
            let directory = recordFilesDirectory(in: deviceRoot)
            try writeRecordFile(filedFirst, into: directory)
            try writeRecordFile(filedSecond, into: directory)

            let store = try makeStore(root: deviceRoot)
            await store.syncRecordFiles(in: directory)

            let survivor = try #require(store.substitutions.first)
            #expect(store.substitutions.count == 1)
            answers.append((survivor.id, survivor.triggerPhrases))
        }

        #expect(answers[0].id == answers[1].id)
        #expect(answers[0].phrases == answers[1].phrases)
        #expect(answers[0].id == filedFirst.id)
        #expect(Set(answers[0].phrases) == ["gleb at gmail", "glep at gmail"])
    }

    @Test("Fixing a typo in a Replacement keeps the entry it was fixed on")
    func editingAReplacementKeepsTheEntry() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)
        let phone = try makeStore(root: makeTempRoot())
        let mac = try makeStore(root: makeTempRoot())

        let entry = Substitution(triggerPhrase: "gleb at gmail", replacement: "gleb@example.co")
        phone.upsert(entry)
        await phone.syncRecordFiles(in: directory)
        await mac.syncRecordFiles(in: directory)

        var fixed = try #require(mac.substitutions.first)
        fixed.replacement = "gleb@example.com"
        mac.upsert(fixed)
        await mac.syncRecordFiles(in: directory)
        await phone.syncRecordFiles(in: directory)

        for device in [phone, mac] {
            #expect(device.substitutions.map(\.id) == [entry.id], "the edit split the entry in two")
            #expect(device.substitutions.first?.replacement == "gleb@example.com")
        }
    }

    @Test("Two Replacements claiming one phrase stay two entries, and clash")
    func differingReplacementsStillClash() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)

        let work = Substitution(
            triggerPhrase: "my email",
            replacement: "gleb@work.example.com",
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        let personal = Substitution(
            triggerPhrase: "my email",
            replacement: "gleb@example.com",
            lastUpdated: Date(timeIntervalSince1970: 2_000)
        )
        try writeRecordFile(work, into: directory)
        try writeRecordFile(personal, into: directory)

        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        #expect(Set(store.substitutions.map(\.id)) == [work.id, personal.id], "a real ambiguity was merged away")
        let clashes = TriggerPhraseClashes(among: store.substitutions)
        #expect(clashes.clashes(for: work).map(\.winningReplacement) == ["gleb@example.com"])
        #expect(clashes.clashes(for: personal).isEmpty)
    }

    // MARK: - Writes

    @Test("An edit lands in the database and in the record files, and survives a relaunch")
    func editsReachTheRecordFiles() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)
        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        let entry = Substitution(triggerPhrase: "ip", replacement: "IP address")
        store.upsert(entry)
        #expect(store.substitutions.count == 1)

        let file = "\(entry.id.uuidString).json"
        #expect(await eventually { self.filenames(in: directory).contains(file) })

        var edited = try #require(store.substitutions.first)
        edited.replacement = "Internet Protocol"
        edited.isEnabled = false
        store.upsert(edited)

        // An edit rewrites the entry's one file rather than adding a second.
        let updated = await eventually {
            let files = self.filenames(in: directory)
            guard files == [file] else { return false }
            let data = (try? Data(contentsOf: directory.appendingPathComponent(file))) ?? Data()
            return (try? SubstitutionJSONCoders.makeDecoder().decode(Substitution.self, from: data))?
                .replacement == "Internet Protocol"
        }
        #expect(updated, "the record file did not follow the edit")

        let relaunched = try makeStore(root: root)
        #expect(relaunched.substitutions.map(\.replacement) == ["Internet Protocol"])
        #expect(relaunched.substitutions.first?.isEnabled == false)
    }

    @Test("A delete writes a tombstone, keeps the snapshot file, and stays deleted across a relaunch")
    func deletesTombstoneTheEntry() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)
        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        let entry = Substitution(triggerPhrase: "secret", replacement: "REDACTED")
        store.upsert(entry)
        let snapshot = "\(entry.id.uuidString).json"
        #expect(await eventually { self.filenames(in: directory).contains(snapshot) })

        store.delete(try #require(store.substitutions.first))
        #expect(store.substitutions.isEmpty)

        let tombstone = "\(entry.id.uuidString).deleted.json"
        #expect(await eventually { self.filenames(in: directory).contains(tombstone) })
        // The snapshot file stays so an unsynced peer still merges the delete.
        #expect(filenames(in: directory).contains(snapshot))

        let relaunched = try makeStore(root: root)
        #expect(relaunched.substitutions.isEmpty)
        await relaunched.syncRecordFiles(in: directory)
        #expect(relaunched.substitutions.isEmpty)
    }

    // MARK: - Delete-vs-edit precedence

    @Test("A delete wins only when it is strictly newer than the edit it deletes")
    func deletePrecedenceIsDecidedOnTheStamps() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = recordFilesDirectory(in: root)

        let resurrected = Substitution(
            triggerPhrase: "back",
            replacement: "re-added",
            lastUpdated: Date(timeIntervalSince1970: 200)
        )
        let tied = Substitution(
            triggerPhrase: "tie",
            replacement: "kept",
            lastUpdated: Date(timeIntervalSince1970: 500)
        )
        try writeRecordFile(resurrected, into: directory)
        try writeTombstoneFile(id: resurrected.id, deletedAt: Date(timeIntervalSince1970: 100), into: directory)
        try writeRecordFile(tied, into: directory)
        try writeTombstoneFile(id: tied.id, deletedAt: Date(timeIntervalSince1970: 500), into: directory)

        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        #expect(Set(store.substitutions.map(\.id)) == [resurrected.id, tied.id])
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

    @Test("LWW: winner decoded from sibling files written by the store's own coders")
    func lwwOverDecodedSiblings() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = recordFilesDirectory(in: root)
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

    // MARK: - Transport

    @Test("Substitutions sync through the existing container — no new entitlement")
    func reusesExistingContainerIdentifier() {
        #expect(ContainerWatcher.containerIdentifier == "iCloud.glebglazov.vcdr")
        #expect(SubstitutionSync.dataset.folder.name == "substitutions")
    }
}
