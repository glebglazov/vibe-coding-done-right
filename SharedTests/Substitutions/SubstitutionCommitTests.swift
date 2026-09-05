import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Exercises the rules that decide what a committed Substitution becomes:
/// trimming, blank entries evaporating, repeated phrases collapsing, and a
/// Trigger Phrase Clash being saved and reported rather than refused. Driven
/// through `SubstitutionsViewModel` over the real Local Store, which is the
/// path both editors take. One source tree compiled into both `vcdr-macTests` and
/// `vcdr-iosTests`.
@MainActor
@Suite("Substitution commit")
struct SubstitutionCommitTests {

    // MARK: - Fixtures

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-commit-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeViewModel(root: URL) async throws -> SubstitutionsViewModel {
        SubstitutionsViewModel(store: try await makeStore(root: root, device: "editing"))
    }

    /// A store over its own database, with the directory of record files
    /// already linked — the state the app reaches once its bootstrap and the
    /// first reconcile pass are done. Two devices are two databases over one
    /// directory.
    private func makeStore(root: URL, device: String) async throws -> LocalSubstitutionStore {
        let store = LocalSubstitutionStore(
            snapshot: try LocalSubstitutionStore.loadSnapshot(
                fileURL: root.appendingPathComponent("\(device).sqlite3")
            )
        )
        await store.syncRecordFiles(in: root.appendingPathComponent("Substitutions", isDirectory: true))
        return store
    }

    private func recordFiles(in root: URL) -> [String] {
        let dir = root.appendingPathComponent("Substitutions", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func snapshotFiles(in root: URL) -> [String] {
        recordFiles(in: root).filter { !$0.hasSuffix(".deleted.json") }
    }

    private func tombstoneFiles(in root: URL) -> [String] {
        recordFiles(in: root).filter { $0.hasSuffix(".deleted.json") }
    }

    private func eventually(timeoutMS: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<max(1, timeoutMS / 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func saved(_ commit: SubstitutionCommit) -> Substitution? {
        guard case .saved(let substitution, _) = commit else { return nil }
        return substitution
    }

    /// What a peer device would load: the record files read into a store of
    /// its own, so tombstones and unwritten entries both show up as absent.
    private func onDisk(_ root: URL) async throws -> [Substitution] {
        try await makeStore(root: root, device: "peer-\(UUID().uuidString)").substitutions
    }

    // MARK: - Blank and duplicate phrases

    @Test("a commit trims, drops blank phrases and collapses a repeat of one it already has")
    func commitTidiesPhrases() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try await makeViewModel(root: root)

        let commit = viewModel.commit(
            Substitution(
                triggerPhrases: ["  power zha ", "", "   ", "Power Zha", "powerja\n"],
                replacement: "  Powierża "
            )
        )

        let entry = try #require(saved(commit))
        #expect(entry.triggerPhrases == ["power zha", "powerja"])
        #expect(entry.replacement == "Powierża")

        // The trailing space would have stopped the phrase firing at all.
        let matcher = SubstitutionMatcher(substitutions: [entry])
        #expect(matcher.apply(to: "Ask power zha and powerja.") == "Ask Powierża and Powierża.")
    }

    @Test("an entry committed with a blank Replacement is deleted instead of persisted")
    func blankReplacementDeletesTheEntry() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try await makeViewModel(root: root)

        let entry = try #require(
            saved(viewModel.commit(Substitution(triggerPhrases: ["oh my zsh"], replacement: "Oh My Zsh")))
        )
        viewModel.drafts = [entry]
        #expect(await eventually { self.snapshotFiles(in: root).count == 1 })

        var blanked = entry
        blanked.replacement = "   "
        let commit = viewModel.commit(blanked)

        #expect(commit == .discarded)
        #expect(viewModel.drafts.isEmpty)
        #expect(await eventually { self.tombstoneFiles(in: root).count == 1 })
        #expect(try await onDisk(root).isEmpty)
    }

    @Test("a new substitution reaches disk only once it carries a Replacement")
    func creatingASubstitutionWritesNothing() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try await makeViewModel(root: root)

        let id = viewModel.add()
        var draft = try #require(viewModel.drafts.first { $0.id == id })
        draft.addPhrase()
        draft[phrase: try #require(draft.livePhrases.first).id] = "oh my zsh"

        #expect(viewModel.commit(draft) == .discarded)
        // Nothing typed into the Replacement yet, so nothing to sync anywhere —
        // but the row the user is still filling in stays in front of him.
        #expect(viewModel.drafts.contains { $0.id == id })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(snapshotFiles(in: root).isEmpty)

        draft.replacement = "Oh My Zsh"
        #expect(try #require(saved(viewModel.commit(draft))).triggerPhrases == ["oh my zsh"])
        #expect(await eventually { self.snapshotFiles(in: root).count == 1 })
        #expect(try await onDisk(root).count == 1)
    }

    // MARK: - Trigger Phrase Clash

    @Test("a phrase two substitutions claim is saved, and the loser is told which Replacement wins")
    func clashIsSavedAndReported() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try await makeViewModel(root: root)

        let older = try #require(
            saved(viewModel.commit(Substitution(triggerPhrases: ["Power Zha"], replacement: "Powierża")))
        )
        let newer = try #require(
            saved(viewModel.commit(Substitution(triggerPhrases: ["power zha", "powerja"], replacement: "Power Ltd")))
        )

        #expect(viewModel.clashes.clashes(for: newer).isEmpty)
        #expect(
            viewModel.clashes.clashes(for: older)
                == [TriggerPhraseClash(phrase: "Power Zha", winningReplacement: "Power Ltd")]
        )
    }

    @Test("the most recently edited substitution wins a clash whatever order the list is in")
    func mostRecentlyEditedWinsRegardlessOfOrder() {
        let older = Substitution(
            triggerPhrases: ["power zha"],
            replacement: "Powierża",
            lastUpdated: Date(timeIntervalSince1970: 1000)
        )
        let newer = Substitution(
            triggerPhrases: ["POWER ZHA"],
            replacement: "Power Ltd",
            lastUpdated: Date(timeIntervalSince1970: 2000)
        )

        for list in [[older, newer], [newer, older]] {
            let clashes = TriggerPhraseClashes(among: list)
            #expect(clashes.clashes(for: newer).isEmpty)
            #expect(clashes.clashes(for: older).first?.winningReplacement == "Power Ltd")
            #expect(SubstitutionMatcher(substitutions: list).apply(to: "Ask Power Zha.") == "Ask Power Ltd.")
        }
    }
}
