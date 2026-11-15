import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// A discarded run's words saved to History, then processed later: the record
/// format, the Local Store's Discarded filter and count, and the proxy that
/// holds writes until the store opens. One source tree compiled into both
/// `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("Discarded Conversations")
struct DiscardedConversationTests {

    private let choice = RecordedOutputChoice(
        platform: .ios,
        modeID: "dictation",
        styleID: "casual",
        displayLabel: "Dictation · Casual"
    )

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-discarded-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func databaseURL(in root: URL) -> URL {
        root.appendingPathComponent("history.sqlite3")
    }

    private func makeStore(root: URL) throws -> LocalHistoryStore {
        LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(fileURL: databaseURL(in: root)))
    }

    private func segments(_ text: String) -> [InputSegment] {
        [InputSegment(text: text)]
    }

    // MARK: - Record format

    @Test("A discarded Conversation survives a JSON round trip under its own key")
    func discardedRoundTrip() throws {
        let conversation = Conversation(
            id: UUID(),
            inputSegments: segments("um so the plan is uh"),
            output: nil,
            label: nil,
            // Whole seconds, because a record file keeps dates to the millisecond.
            lastUpdated: Date(timeIntervalSinceReferenceDate: 800_000_000),
            status: .discarded(choice)
        )

        let data = try HistoryJSONCoders.makeEncoder().encode(conversation)
        let decoded = try HistoryJSONCoders.makeDecoder().decode(Conversation.self, from: data)

        #expect(decoded == conversation)
        #expect(decoded.extras.isEmpty)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let discarded = try #require(object["discarded"] as? [String: String])
        #expect(discarded == [
            "platform": "ios", "mode": "dictation", "style": "casual", "label": "Dictation · Casual",
        ])
    }

    @Test("A record without the discarded key is a normal entry, and writes none back")
    func oldRecordIsNormal() throws {
        let json = """
            {"id":"\(UUID().uuidString)",\
            "segments":[{"id":"\(UUID().uuidString)","text":"hello"}],\
            "output":"Hello.",\
            "lastUpdated":"2025-03-01T10:00:00Z",\
            "schemaVersion":1}
            """

        let decoded = try HistoryJSONCoders.makeDecoder().decode(Conversation.self, from: Data(json.utf8))
        let reencoded = try HistoryJSONCoders.makeEncoder().encode(decoded)

        #expect(decoded.status == .normal)
        #expect(decoded.extras.isEmpty)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("discarded"))
    }

    // MARK: - Local Store

    @Test("Processing a discarded entry makes it normal, with its output and its capture time")
    func resolveKeepsCaptureTime() throws {
        let root = makeTempRoot()
        let store = try makeStore(root: root)
        let id = UUID()

        store.recordDiscarded(conversationID: id, inputSegments: segments("um the words"), choice: choice)
        let discarded = try #require(store.conversations.first)
        #expect(discarded.status == .discarded(choice))
        #expect(discarded.output == nil)
        #expect(store.discardedCount == 1)

        store.resolveDiscarded(conversationID: id, output: "The words.", label: "Dictation")

        let relaunched = try makeStore(root: root)
        for resolved in [try #require(store.conversations.first), try #require(relaunched.conversations.first)] {
            #expect(resolved.id == id)
            #expect(resolved.status == .normal)
            #expect(resolved.output == "The words.")
            #expect(resolved.label == "Dictation")
            #expect(resolved.inputText == "um the words")
            #expect(resolved.capturedAt == discarded.capturedAt)
            #expect(resolved.lastUpdated > discarded.lastUpdated)
        }
        #expect(store.discardedCount == 0)
        #expect(relaunched.discardedCount == 0)
    }

    @Test("Processing an entry that is gone does nothing")
    func resolveGoneIsNoOp() throws {
        let store = try makeStore(root: makeTempRoot())

        store.resolveDiscarded(conversationID: UUID(), output: "Lost.", label: nil)

        #expect(store.conversations.isEmpty)
    }

    @Test("The Discarded filter pages only discarded entries, and the count follows every write")
    func filterAndCount() throws {
        let store = try makeStore(root: makeTempRoot())
        let discardedIDs = (0..<3).map { _ in UUID() }
        for index in 0...LocalHistoryStore.pageSize {
            store.record(conversationID: UUID(), inputSegments: segments("normal \(index)"), output: nil, label: nil)
        }
        for id in discardedIDs {
            store.recordDiscarded(conversationID: id, inputSegments: segments("discarded"), choice: choice)
        }
        #expect(store.discardedCount == 3)

        store.filter = .discarded
        #expect(Set(store.conversations.map(\.id)) == Set(discardedIDs))
        #expect(!store.hasMorePages)

        store.resolveDiscarded(conversationID: discardedIDs[0], output: "Done.", label: nil)
        #expect(store.discardedCount == 2)
        #expect(store.conversations.map(\.id) == [discardedIDs[2], discardedIDs[1]])

        store.removeConversation(id: try #require(store.conversations.first).id)
        #expect(store.discardedCount == 1)
        #expect(store.conversations.map(\.id) == [discardedIDs[1]])

        store.record(conversationID: UUID(), inputSegments: segments("new normal"), output: nil, label: nil)
        #expect(store.conversations.map(\.id) == [discardedIDs[1]])

        store.filter = .all
        #expect(store.conversations.count == LocalHistoryStore.pageSize)
        #expect(store.hasMorePages)
        #expect(store.conversations.contains { $0.id == discardedIDs[0] && $0.status == .normal })
    }

    @Test("A discarded record another device wrote arrives counted, and its resolve arrives too")
    func mergedDiscardedRecordIsCounted() async throws {
        let root = makeTempRoot()
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        let archive = ConversationFileArchive(directory: directory)
        archive.ensureDirectoryExists()
        let encoder = HistoryJSONCoders.makeEncoder()
        let capturedAt = Date().addingTimeInterval(-60)
        let id = UUID()
        let filename = ConversationFileArchive.snapshotFilename(id: id, createdAt: capturedAt)
        var peerCopy = Conversation(
            id: id,
            inputSegments: segments("from the Mac"),
            output: nil,
            label: nil,
            capturedAt: capturedAt,
            lastUpdated: capturedAt,
            status: .discarded(RecordedOutputChoice(
                platform: .mac, modeID: UUID().uuidString, styleID: nil, displayLabel: "Notes"
            ))
        )
        _ = archive.writeSnapshot(peerCopy, named: filename, encoder: encoder)
        let store = try makeStore(root: root)
        store.filter = .discarded

        await store.syncRecordFiles(in: directory)
        #expect(store.discardedCount == 1)
        #expect(store.conversations.map(\.id) == [peerCopy.id])

        peerCopy.output = "From the Mac."
        peerCopy.status = .normal
        peerCopy.lastUpdated = Date()
        _ = archive.writeSnapshot(peerCopy, named: filename, encoder: encoder)

        await store.syncRecordFiles(in: directory)
        #expect(store.discardedCount == 0)
        #expect(store.conversations.isEmpty)
    }

    @Test("A database from before Conversation status counts the discarded records it already holds")
    func upgradedDatabaseAdoptsDiscardedFlags() throws {
        let root = makeTempRoot()
        try writeLegacyDatabase(at: databaseURL(in: root))

        let store = try makeStore(root: root)

        #expect(store.conversations.count == 2)
        #expect(store.discardedCount == 1)
    }

    @Test("A discarded record an older build wrote into the shared database is counted at the next open")
    func olderBuildWriteIsReconciled() throws {
        let root = makeTempRoot()
        let store = try makeStore(root: root)
        let resolvedByPeer = UUID()
        store.recordDiscarded(conversationID: resolvedByPeer, inputSegments: segments("resolved elsewhere"), choice: choice)
        #expect(store.discardedCount == 1)

        // An older build knows no "discarded" column: it inserts with the
        // column's default and updates without touching it. Its payloads keep
        // the status in their unknown keys.
        let olderBuild = try SQLiteDatabase(fileURL: databaseURL(in: root))
        let encoder = HistoryJSONCoders.makeEncoder()
        let now = Date()
        let mergedFromPeer = Conversation(
            id: UUID(), inputSegments: segments("discarded on a peer"), output: nil, label: nil,
            lastUpdated: now, status: .discarded(choice)
        )
        try olderBuild.run(
            """
            INSERT INTO conversations (id, captured_at, last_updated, payload, record_filename, exported)
            VALUES (?, ?, ?, ?, ?, 1)
            """,
            [
                .text(mergedFromPeer.id.uuidString),
                .double(now.timeIntervalSinceReferenceDate),
                .double(now.timeIntervalSinceReferenceDate),
                .blob(try encoder.encode(mergedFromPeer)),
                .text(ConversationFileArchive.snapshotFilename(id: mergedFromPeer.id, createdAt: now)),
            ]
        )
        let resolved = Conversation(
            id: resolvedByPeer, inputSegments: segments("resolved elsewhere"), output: "Resolved.", label: nil,
            lastUpdated: now
        )
        try olderBuild.run(
            "UPDATE conversations SET payload = ?, last_updated = ? WHERE id = ?",
            [.blob(try encoder.encode(resolved)), .double(now.timeIntervalSinceReferenceDate), .text(resolvedByPeer.uuidString)]
        )
        try olderBuild.run(
            "INSERT INTO conversations (id, captured_at, last_updated, payload, record_filename, exported) VALUES (?, 0, 0, ?, 'x', 1)",
            [.text(UUID().uuidString), .blob(Data("not json".utf8))]
        )

        let reopened = try makeStore(root: root)
        reopened.filter = .discarded

        #expect(reopened.discardedCount == 1)
        #expect(reopened.conversations.map(\.id) == [mergedFromPeer.id])
    }

    /// The conversations table as a build before Conversation status left it,
    /// holding one normal and one discarded record.
    private func writeLegacyDatabase(at fileURL: URL) throws {
        let legacy = try SQLiteDatabase(fileURL: fileURL)
        try legacy.execute("""
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY NOT NULL,
                captured_at REAL NOT NULL,
                last_updated REAL NOT NULL,
                payload BLOB NOT NULL,
                record_filename TEXT NOT NULL,
                exported INTEGER NOT NULL
            );
            """)
        let now = Date()
        for status in [ConversationStatus.normal, .discarded(choice)] {
            let conversation = Conversation(
                id: UUID(), inputSegments: segments("kept"), output: nil, label: nil, lastUpdated: now, status: status
            )
            try legacy.run(
                "INSERT INTO conversations VALUES (?, ?, ?, ?, ?, 1)",
                [
                    .text(conversation.id.uuidString),
                    .double(now.timeIntervalSinceReferenceDate),
                    .double(now.timeIntervalSinceReferenceDate),
                    .blob(try HistoryJSONCoders.makeEncoder().encode(conversation)),
                    .text(ConversationFileArchive.snapshotFilename(id: conversation.id, createdAt: now)),
                ]
            )
        }
    }

    // MARK: - Proxy

    @Test("Writes made before the store opens land in order once it does")
    func proxyFlushesInOrder() throws {
        let proxy = HistoryStoreProxy()
        let id = UUID()
        proxy.filter = .discarded
        proxy.recordDiscarded(conversationID: id, inputSegments: segments("early"), choice: choice)
        #expect(proxy.discardedCount == 1)
        #expect(proxy.conversations.map(\.id) == [id])

        proxy.resolveDiscarded(conversationID: id, output: "Early.", label: nil)
        #expect(proxy.discardedCount == 0)
        #expect(proxy.conversations.isEmpty)

        let store = try makeStore(root: makeTempRoot())
        proxy.setRealStore(store)
        proxy.filter = .all

        #expect(store.discardedCount == 0)
        #expect(store.conversations.map(\.output) == ["Early."])
        #expect(store.conversations.first?.status == .normal)
    }
}
