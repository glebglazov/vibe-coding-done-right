import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Drives the Local Store through the path the app uses: a database opened
/// from disk, the record files linked behind it, then reads and writes going
/// through the `HistoryStore` protocol. One source tree compiled into both
/// `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("LocalHistoryStore")
struct LocalHistoryStoreTests {

    // MARK: - Fixtures

    /// A fresh, isolated storage root per call so tests never share state —
    /// neither the database file nor the record files.
    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-local-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func databaseURL(in root: URL) -> URL {
        root.appendingPathComponent("history.sqlite3")
    }

    private func recordFilesDirectory(in root: URL) -> URL {
        root.appendingPathComponent("conversations", isDirectory: true)
    }

    /// Writes a record file the way a peer device would have left it —
    /// hand-rolled JSON so an unknown top-level key can be planted in it.
    @discardableResult
    private func writeRecordFile(
        id: UUID,
        createdAt: Date,
        text: String,
        futureField: String? = nil,
        into directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: createdAt)
        let future = futureField.map { ",\"futureField\":\"\($0)\"" } ?? ""
        let json = """
            {"id":"\(id.uuidString)",\
            "segments":[{"id":"\(UUID().uuidString)","text":"\(text)"}],\
            "lastUpdated":"\(stamp)",\
            "schemaVersion":1\(future)}
            """
        let url = directory.appendingPathComponent(
            ConversationFileArchive.snapshotFilename(id: id, createdAt: createdAt)
        )
        try Data(json.utf8).write(to: url)
        return url
    }

    private func writeTombstoneFile(id: UUID, deletedAt: Date, into directory: URL) {
        ConversationFileArchive(directory: directory).writeTombstone(
            id: id,
            deletedAt: deletedAt,
            encoder: HistoryJSONCoders.makeEncoder()
        )
    }

    private func makeStore(root: URL) throws -> LocalHistoryStore {
        LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(fileURL: databaseURL(in: root)))
    }

    /// Every file in a directory with its bytes and mtime — what proves the
    /// import left the record files exactly as it found them.
    private func inventory(of directory: URL) -> [String: (Data, Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var inventory: [String: (Data, Date)] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let modifiedAt = ConversationFileArchive.modificationDate(of: url) else { continue }
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

    @Test("Reads the record files in, suppressing tombstoned records and keeping unknown keys")
    func readsRecordFilesIn() async throws {
        let root = makeTempRoot()
        let directory = recordFilesDirectory(in: root)
        let kept = UUID()
        let withFutureField = UUID()
        let deleted = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

        try writeRecordFile(id: kept, createdAt: base, text: "kept", into: directory)
        try writeRecordFile(
            id: withFutureField,
            createdAt: base.addingTimeInterval(1),
            text: "newer schema",
            futureField: "keep me",
            into: directory
        )
        try writeRecordFile(id: deleted, createdAt: base.addingTimeInterval(2), text: "gone", into: directory)
        writeTombstoneFile(id: deleted, deletedAt: Date(), into: directory)

        let before = inventory(of: directory)

        let store = try makeStore(root: root)
        #expect(store.conversations.isEmpty, "the database is empty until the record files are linked")

        await store.syncRecordFiles(in: directory)

        #expect(Set(store.conversations.map(\.id)) == [kept, withFutureField])
        let imported = try #require(store.conversations.first { $0.id == withFutureField })
        #expect(imported.extras["futureField"] == .string("keep me"))
        #expect(imported.inputText == "newer schema")

        // The record files are the rollback path: the merge only reads them.
        let after = inventory(of: directory)
        #expect(after.count == before.count)
        for (name, snapshot) in before {
            let current = after[name]
            #expect(current?.0 == snapshot.0, "\(name) was rewritten")
            #expect(current?.1 == snapshot.1, "\(name) was touched")
        }

        // Relaunch: the list answers from the database alone, and a second
        // pass over the same directory changes nothing.
        let relaunched = try makeStore(root: root)
        #expect(Set(relaunched.conversations.map(\.id)) == [kept, withFutureField])
        await relaunched.syncRecordFiles(in: directory)
        #expect(relaunched.conversations.count == 2)
        #expect(filenames(in: directory) == Set(before.keys))
    }

    // MARK: - Another device

    @Test("A record another device wrote arrives here, and a delete on either removes it on both")
    func recordsTravelBetweenDevices() async throws {
        let directory = recordFilesDirectory(in: makeTempRoot())
        let thisDevice = try makeStore(root: makeTempRoot())
        let otherDevice = try makeStore(root: makeTempRoot())
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)

        let fromOther = UUID()
        otherDevice.record(
            conversationID: fromOther,
            inputSegments: [InputSegment(text: "dictated over there")],
            output: nil,
            label: nil
        )
        await otherDevice.syncRecordFiles(in: directory)

        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.conversations.map(\.id) == [fromOther])
        #expect(thisDevice.latestConversation?.inputText == "dictated over there")

        // An edit there reaches here too, over the record it already holds.
        otherDevice.record(
            conversationID: fromOther,
            inputSegments: [InputSegment(text: "dictated over there")],
            output: "and processed there",
            label: nil
        )
        await otherDevice.syncRecordFiles(in: directory)
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.conversations.map(\.output) == ["and processed there"])

        // The other device deletes it; this one stops showing it, and keeps it
        // gone however many passes follow.
        let arrived = try #require(otherDevice.conversations.first { $0.id == fromOther })
        otherDevice.removeConversation(arrived)
        await otherDevice.syncRecordFiles(in: directory)

        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.conversations.isEmpty)
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.conversations.isEmpty, "a later pass resurrected the deleted record")

        // A delete made here reaches the other device the same way.
        let fromHere = UUID()
        thisDevice.record(
            conversationID: fromHere,
            inputSegments: [InputSegment(text: "dictated over here")],
            output: nil,
            label: nil
        )
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)
        #expect(otherDevice.conversations.map(\.id) == [fromHere])

        thisDevice.removeConversation(try #require(thisDevice.latestConversation))
        await thisDevice.syncRecordFiles(in: directory)
        #expect(thisDevice.conversations.isEmpty, "the pass that exported the delete undid it")
        await otherDevice.syncRecordFiles(in: directory)
        #expect(otherDevice.conversations.isEmpty)
    }

    // MARK: - Writes

    @Test("A recorded conversation lands in the database and in the record files")
    func writesReachTheRecordFiles() async throws {
        let root = makeTempRoot()
        let directory = recordFilesDirectory(in: root)
        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        let id = UUID()
        store.record(
            conversationID: id,
            inputSegments: [InputSegment(text: "dictated")],
            output: "processed",
            label: nil
        )

        #expect(store.latestConversation?.id == id)
        let exported = await eventually { filenames(in: directory).contains { $0.contains(id.uuidString) } }
        #expect(exported, "the record file never appeared")

        // An edit rewrites the same file rather than adding a second one.
        store.record(
            conversationID: id,
            inputSegments: [InputSegment(text: "dictated again")],
            output: "processed again",
            label: "Label"
        )
        let updated = await eventually {
            let files = filenames(in: directory).filter { $0.contains(id.uuidString) }
            guard files.count == 1, let name = files.first else { return false }
            let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
            let conversation = try? HistoryJSONCoders.makeDecoder().decode(Conversation.self, from: data)
            return conversation?.output == "processed again"
        }
        #expect(updated, "the record file did not follow the edit")

        // A relaunch reads the edit back out of the database.
        let relaunched = try makeStore(root: root)
        #expect(relaunched.conversations.map(\.output) == ["processed again"])
    }

    @Test("A delete tombstones the record and stays deleted across a relaunch")
    func deletesTombstoneTheRecordFile() async throws {
        let root = makeTempRoot()
        let directory = recordFilesDirectory(in: root)
        let store = try makeStore(root: root)
        await store.syncRecordFiles(in: directory)

        let id = UUID()
        store.record(
            conversationID: id,
            inputSegments: [InputSegment(text: "to delete")],
            output: nil,
            label: nil
        )
        let conversation = try #require(store.latestConversation)
        store.removeConversation(conversation)

        #expect(store.conversations.isEmpty)
        let tombstoned = await eventually {
            filenames(in: directory).contains {
                $0.contains(id.uuidString) && $0.hasSuffix(".deleted.json")
            }
        }
        #expect(tombstoned, "no tombstone reached the record files")

        let relaunched = try makeStore(root: root)
        #expect(relaunched.conversations.isEmpty)
    }
}
