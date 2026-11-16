import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// A query over every stored conversation, not only the loaded page. One
/// source tree compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("Conversation query")
struct ConversationQueryTests {

    @Test("finds the matching conversations, loaded or not")
    func findsMatchesBeyondTheLoadedPage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("history.sqlite3")
        let writer = LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(fileURL: fileURL))

        var wanted: Set<UUID> = []
        for index in 0..<(LocalHistoryStore.pageSize + 5) {
            let id = UUID()
            let label = index.isMultiple(of: 10) ? "Wanted" : "Other"
            writer.record(conversationID: id, inputSegments: [InputSegment(text: "\(index)")], output: nil, label: label)
            if label == "Wanted" { wanted.insert(id) }
        }

        let reader = LocalHistoryStore(snapshot: try LocalHistoryStore.loadSnapshot(fileURL: fileURL))
        #expect(reader.conversations.count == LocalHistoryStore.pageSize)

        let found = await reader.conversationIDs { $0.label == "Wanted" }
        #expect(Set(found) == wanted)
    }
}
