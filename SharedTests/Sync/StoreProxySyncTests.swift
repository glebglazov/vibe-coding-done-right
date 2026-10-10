import Foundation
import SwiftUI
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// What the screens and the recording pipeline see after a sync pass brings in
/// another device's records. They read through the launch-time proxies, so a
/// pass the real store took in must show through them. One source tree compiled
/// into both `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("What the screens see after a sync pass")
struct StoreProxySyncTests {

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-proxy-sync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSubstitutionStore(root: URL) throws -> LocalSubstitutionStore {
        LocalSubstitutionStore(
            snapshot: try LocalSubstitutionStore.loadSnapshot(
                fileURL: root.appendingPathComponent("substitutions.sqlite3")
            )
        )
    }

    private func makeHistoryStore(root: URL) throws -> LocalHistoryStore {
        LocalHistoryStore(
            snapshot: try LocalHistoryStore.loadSnapshot(
                fileURL: root.appendingPathComponent("history.sqlite3")
            )
        )
    }

    /// Whether reading `read` registered a dependency that `change` then fires,
    /// which is what makes SwiftUI redraw a view that read it.
    private func invalidates(
        _ read: () -> Void,
        when change: () async -> Void
    ) async -> Bool {
        var fired = false
        withObservationTracking(read) { fired = true }
        await change()
        return fired
    }

    @Test("A Dictionary entry another device wrote shows through the proxy, and redraws what read it")
    func substitutionFromAnotherDevice() async throws {
        let directory = makeTempRoot().appendingPathComponent("Substitutions", isDirectory: true)
        let thisDevice = try makeSubstitutionStore(root: makeTempRoot())
        let otherDevice = try makeSubstitutionStore(root: makeTempRoot())
        let proxy = SubstitutionStoreProxy()
        proxy.setRealStore(thisDevice)
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)

        let fromOther = Substitution(triggerPhrase: "ip", replacement: "IP address")
        otherDevice.upsert(fromOther)
        await otherDevice.syncRecordFiles(in: directory)

        let redrawn = await invalidates({ _ = proxy.substitutions }) {
            await thisDevice.syncRecordFiles(in: directory)
        }
        #expect(proxy.substitutions.map(\.id) == [fromOther.id])
        #expect(redrawn, "a view reading the proxy was not told about the pass")
    }

    @Test("Dictionary edits made before the store opens show at once and reach it when it does")
    func substitutionEditedBeforeTheStoreOpens() async throws {
        let proxy = SubstitutionStoreProxy()
        let early = Substitution(triggerPhrase: "ip", replacement: "IP address")
        proxy.upsert(early)
        #expect(proxy.substitutions.map(\.id) == [early.id])

        let store = try makeSubstitutionStore(root: makeTempRoot())
        proxy.setRealStore(store)
        #expect(store.substitutions.map(\.id) == [early.id])
        #expect(proxy.substitutions.map(\.id) == [early.id])
    }

    @Test("The open Dictionary list takes in another device's entries without moving rows or undoing typing")
    func openDictionaryListTakesInAPass() async throws {
        let directory = makeTempRoot().appendingPathComponent("Substitutions", isDirectory: true)
        let thisDevice = try makeSubstitutionStore(root: makeTempRoot())
        let otherDevice = try makeSubstitutionStore(root: makeTempRoot())
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)

        let older = Substitution(triggerPhrase: "vcdr", replacement: "VCDR")
        let newer = Substitution(triggerPhrase: "ip", replacement: "IP address")
        let doomed = Substitution(triggerPhrase: "tmp", replacement: "temporary")
        for entry in [older, newer, doomed] { otherDevice.upsert(entry) }
        await otherDevice.syncRecordFiles(in: directory)
        await thisDevice.syncRecordFiles(in: directory)

        let viewModel = SubstitutionsViewModel(store: thisDevice)
        let order = viewModel.drafts.map(\.id)

        // Typing here: a trailing space the commit trims, and a new row with
        // nothing in it yet.
        var typing = try #require(viewModel.drafts.first { $0.id == older.id })
        typing.replacement = "VCDR "
        viewModel.binding(for: older.id).wrappedValue = typing
        viewModel.commit(typing)
        let blank = viewModel.add()

        // The other device edits one entry, deletes another, and adds a third.
        var edited = try #require(otherDevice.substitutions.first { $0.id == newer.id })
        edited.replacement = "Internet Protocol"
        otherDevice.upsert(edited)
        otherDevice.delete(try #require(otherDevice.substitutions.first { $0.id == doomed.id }))
        let added = Substitution(triggerPhrase: "llm", replacement: "LLM")
        otherDevice.upsert(added)
        await otherDevice.syncRecordFiles(in: directory)

        await thisDevice.syncRecordFiles(in: directory)
        viewModel.syncFromStore()

        let expectedOrder = [added.id] + order.filter { $0 != doomed.id } + [blank]
        #expect(viewModel.drafts.map(\.id) == expectedOrder, "rows moved, or an arrival or delete was missed")
        #expect(viewModel.drafts.first { $0.id == newer.id }?.replacement == "Internet Protocol")
        #expect(viewModel.drafts.first { $0.id == older.id }?.replacement == "VCDR ", "the pass undid typing in progress")
    }

    @Test("A conversation another device recorded shows through the proxy, and redraws what read it")
    func conversationFromAnotherDevice() async throws {
        let directory = makeTempRoot().appendingPathComponent("History", isDirectory: true)
        let thisDevice = try makeHistoryStore(root: makeTempRoot())
        let otherDevice = try makeHistoryStore(root: makeTempRoot())
        let proxy = HistoryStoreProxy()
        proxy.setRealStore(thisDevice)
        await thisDevice.syncRecordFiles(in: directory)
        await otherDevice.syncRecordFiles(in: directory)

        let id = UUID()
        otherDevice.record(conversationID: id, inputSegments: [], output: "from the other device", label: nil)
        await otherDevice.syncRecordFiles(in: directory)

        let redrawn = await invalidates({ _ = proxy.conversations }) {
            await thisDevice.syncRecordFiles(in: directory)
        }
        #expect(proxy.conversations.map(\.id) == [id])
        #expect(proxy.latestConversation?.id == id)
        #expect(redrawn, "a view reading the proxy was not told about the pass")
    }

    @Test("A conversation recorded before the store opens shows at once and reaches it when it does")
    func conversationRecordedBeforeTheStoreOpens() async throws {
        let proxy = HistoryStoreProxy()
        let id = UUID()
        proxy.record(conversationID: id, inputSegments: [], output: "early", label: nil)
        #expect(proxy.conversations.map(\.id) == [id])
        #expect(proxy.latestConversation?.id == id)

        let store = try makeHistoryStore(root: makeTempRoot())
        proxy.setRealStore(store)
        #expect(store.conversations.map(\.id) == [id])
        #expect(proxy.conversations.map(\.id) == [id])
    }
}
