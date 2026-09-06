import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Which Record Files count as one Synced Dataset's. Every dataset's files
/// arrive through one container query, so this test is the whole of what keeps
/// a Substitution landing from starting a Sync Pass over history. One source
/// tree compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@Suite("Container folder")
struct ContainerFolderTests {

    private let root = URL(fileURLWithPath: "/Container/Documents/VCDR", isDirectory: true)

    private var conversations: ContainerFolder {
        ContainerFolder(root.appendingPathComponent("conversations", isDirectory: true))
    }

    @Test("a Record File in the folder is the folder's")
    func holdsItsOwnRecordFiles() {
        #expect(conversations.holds(root.appendingPathComponent("conversations/2026-01-01_a.json")))
    }

    @Test("another dataset's Record File is not")
    func rejectsAnotherFolder() {
        #expect(!conversations.holds(root.appendingPathComponent("substitutions/a.json")))
    }

    @Test("a folder whose name only begins with this one's is not this one")
    func rejectsAFolderSharingAPrefix() {
        #expect(!conversations.holds(root.appendingPathComponent("conversations-archive/a.json")))
    }

    @Test("the case the filesystem reports does not decide it")
    func foldsCase() {
        #expect(conversations.holds(root.appendingPathComponent("Conversations/a.json")))
        #expect(ContainerFolder(root.appendingPathComponent("Substitutions", isDirectory: true))
            .holds(root.appendingPathComponent("substitutions/a.json")))
    }
}
