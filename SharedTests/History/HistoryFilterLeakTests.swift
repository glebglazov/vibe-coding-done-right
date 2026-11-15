import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// The History filter is for the history views only. Copy Latest, the menu and
/// a cancelled preview read and write the store whatever the list shows. One
/// source tree compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("History readers outside the list")
struct HistoryFilterLeakTests {

    private let choice = RecordedOutputChoice(
        platform: .mac, modeID: "dictation", styleID: nil, displayLabel: "Dictation"
    )

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-filter-leak-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(root: URL) throws -> LocalHistoryStore {
        LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(
            fileURL: root.appendingPathComponent("history.sqlite3")
        ))
    }

    private func record(_ store: LocalHistoryStore, _ text: String) -> UUID {
        let id = UUID()
        store.record(conversationID: id, inputSegments: [InputSegment(text: text)], output: nil, label: nil)
        return id
    }

    @Test("The latest conversation is the newest normal one, whatever the filter")
    func latestSkipsDiscardedAndIgnoresTheFilter() throws {
        let root = makeRoot()
        let store = try makeStore(root: root)
        let kept = record(store, "kept words")
        store.recordDiscarded(conversationID: UUID(), inputSegments: [InputSegment(text: "discarded")], choice: choice)

        #expect(store.latestConversation?.id == kept)
        store.filter = .discarded
        #expect(store.latestConversation?.id == kept)
        #expect(try makeStore(root: root).latestConversation?.id == kept)

        store.removeConversation(id: kept)
        #expect(store.latestConversation == nil)
    }

    @Test("The latest conversation follows a record another device wrote")
    func latestFollowsAMerge() async throws {
        let directory = makeRoot().appendingPathComponent("conversations", isDirectory: true)
        let otherDevice = try makeStore(root: makeRoot())
        await otherDevice.syncRecordFiles(in: directory)
        let thisDevice = try makeStore(root: makeRoot())
        thisDevice.filter = .discarded

        let fromOther = record(otherDevice, "from the other device")
        await otherDevice.syncRecordFiles(in: directory)
        await thisDevice.syncRecordFiles(in: directory)

        #expect(thisDevice.latestConversation?.id == fromOther)
    }

    @Test("A conversation the filter hides can still be removed by its id")
    func removeByIDIgnoresTheFilter() throws {
        let root = makeRoot()
        let store = try makeStore(root: root)
        let previewed = record(store, "a preview cancelled later")
        store.filter = .discarded
        #expect(store.conversations.isEmpty)

        store.removeConversation(id: previewed)

        store.filter = .all
        #expect(store.conversations.isEmpty)
        #expect(try makeStore(root: root).conversations.isEmpty)
    }

    @Test("Before the store opens, the latest conversation is the newest normal write")
    func proxyLatestSkipsDiscarded() {
        let proxy = HistoryStoreProxy()
        let kept = UUID()
        proxy.record(conversationID: kept, inputSegments: [InputSegment(text: "kept")], output: nil, label: nil)
        proxy.recordDiscarded(conversationID: UUID(), inputSegments: [InputSegment(text: "discarded")], choice: choice)
        proxy.filter = .discarded

        #expect(proxy.latestConversation?.id == kept)
    }
}
