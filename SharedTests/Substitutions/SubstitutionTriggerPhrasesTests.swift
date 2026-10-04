import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Exercises a Substitution holding several Trigger Phrases: every phrase
/// rewriting to the one Replacement, phrases competing against other entries in
/// the same candidate pass, and the on-disk shape that keeps a pre-array build
/// from losing the entry (ADR-0008). One source tree compiled into both
/// `vcdr-macTests` and `vcdr-iosTests`.
@MainActor
@Suite("Substitution Trigger Phrases")
struct SubstitutionTriggerPhrasesTests {

    // MARK: - Fixtures

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-phrases-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a raw JSON snapshot so a file shape this build never produces —
    /// a previous build's, or a future build's — can be fed to the real scan.
    private func writeRawSnapshot(_ json: String, id: UUID, into root: URL) throws -> URL {
        let dir = root.appendingPathComponent("Substitutions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// A store over its own database, with the directory of record files
    /// already linked — the state the app reaches once its bootstrap and the
    /// first reconcile pass are done.
    private func makeStore(root: URL) async throws -> LocalSubstitutionStore {
        let store = LocalSubstitutionStore(
            snapshot: try LocalSubstitutionStore.loadSnapshot(
                fileURL: root.appendingPathComponent("substitutions.sqlite3")
            )
        )
        await store.syncRecordFiles(in: root.appendingPathComponent("Substitutions", isDirectory: true))
        return store
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require(raw as? [String: Any])
    }

    private func eventually(timeoutMS: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<max(1, timeoutMS / 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Matching

    @Test("every Trigger Phrase on one Substitution rewrites to the same Replacement")
    func everyPhraseRewrites() {
        let sut = SubstitutionMatcher(substitutions: [
            Substitution(
                triggerPhrases: ["power zha", "powerja", "powerzha"],
                replacement: "Powierża"
            )
        ])

        let output = sut.apply(to: "Ask power zha, then powerja, then Powerzha.")

        #expect(output == "Ask Powierża, then Powierża, then Powierża.")
    }

    @Test("a long phrase on one Substitution beats a short phrase on another")
    func longestPhraseWinsAcrossEntries() {
        let sut = SubstitutionMatcher(substitutions: [
            Substitution(triggerPhrases: ["mail", "email"], replacement: "SHORT"),
            Substitution(triggerPhrases: ["my work email", "my personal email"], replacement: "gleb@example.com"),
        ])

        let output = sut.apply(to: "Send it to my personal email today.")

        #expect(output == "Send it to gleb@example.com today.")
    }

    // MARK: - Storage

    @Test("a file written by the previous build loads with its single phrase intact")
    func previousBuildFileLoads() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        _ = try writeRawSnapshot(
            """
            {"id":"\(id.uuidString)","isEnabled":true,\
            "lastUpdated":"2026-01-01T09:30:00.000Z",\
            "replacement":"Oh My Zsh","triggerPhrase":"oh my zsh"}
            """,
            id: id,
            into: root
        )

        let arrayID = UUID()
        _ = try writeRawSnapshot(
            """
            {"id":"\(arrayID.uuidString)","isEnabled":true,\
            "lastUpdated":"2026-01-01T09:30:00.000Z",\
            "replacement":"Powierża","triggerPhrase":"power zha",\
            "triggerPhrases":["power zha","powerja"]}
            """,
            id: arrayID,
            into: root
        )

        let store = try await makeStore(root: root)

        #expect(store.substitutions.count == 2)
        let singular = try #require(store.substitutions.first { $0.id == id })
        #expect(singular.triggerPhrases == ["oh my zsh"])
        #expect(singular.replacement == "Oh My Zsh")
        #expect(singular.note.isEmpty)
        // The phrases a build wrote before they carried stamps count as added
        // when it last wrote them, which is all that file can say.
        let plural = try #require(store.substitutions.first { $0.id == arrayID })
        #expect(plural.triggerPhrases == ["power zha", "powerja"])
        #expect(plural.livePhrases.map(\.addedAt) == [plural.lastUpdated, plural.lastUpdated])
    }

    @Test("a file written by this build still carries the singular key, set to the first phrase")
    func writesTheSingularKeyForOlderReaders() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await makeStore(root: root)
        let entry = Substitution(triggerPhrases: ["power zha", "powerja"], replacement: "Powierża")
        store.upsert(entry)

        let url = root.appendingPathComponent("Substitutions", isDirectory: true)
            .appendingPathComponent("\(entry.id.uuidString).json")
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })

        let written = try jsonObject(at: url)
        #expect(written["triggerPhrase"] as? String == "power zha")
        #expect(written["triggerPhrases"] as? [String] == ["power zha", "powerja"])

        // The phrases this build works through carry their own stamps beside
        // the two landing pads.
        let stamped = try #require(written["phrases"] as? [[String: Any]])
        #expect(stamped.compactMap { $0["text"] as? String } == ["power zha", "powerja"])
        #expect(stamped.allSatisfy { $0["addedAt"] is String && $0["removedAt"] == nil })
    }

    @Test("a phrase taken off the entry leaves the older builds' keys and stays off")
    func removedPhrasesLeaveTheLandingPads() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await makeStore(root: root)
        var entry = Substitution(triggerPhrases: ["power zha", "powerja"], replacement: "Powierża")
        entry.removePhrase(try #require(entry.livePhrases.first).id)
        store.upsert(entry)

        let url = root.appendingPathComponent("Substitutions", isDirectory: true)
            .appendingPathComponent("\(entry.id.uuidString).json")
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })

        let written = try jsonObject(at: url)
        #expect(written["triggerPhrase"] as? String == "powerja")
        #expect(written["triggerPhrases"] as? [String] == ["powerja"])
        #expect((written["phrases"] as? [[String: Any]])?.count == 2, "the removal is what keeps it removed")

        let relaunched = LocalSubstitutionStore(
            snapshot: try LocalSubstitutionStore.loadSnapshot(
                fileURL: root.appendingPathComponent("substitutions.sqlite3")
            )
        )
        #expect(relaunched.substitutions.first?.triggerPhrases == ["powerja"])
    }

    @Test("keys this build does not recognise survive a load and a re-save")
    func unknownKeysSurviveARewrite() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let url = try writeRawSnapshot(
            """
            {"id":"\(id.uuidString)","isEnabled":true,\
            "lastUpdated":"2026-01-01T09:30:00.000Z",\
            "replacement":"Oh My Zsh","triggerPhrase":"oh my zsh",\
            "fromANewerBuild":{"caseSensitive":true}}
            """,
            id: id,
            into: root
        )

        let store = try await makeStore(root: root)
        var loaded = try #require(store.substitutions.first)
        loaded.replacement = "Oh My Zsh!"
        store.upsert(loaded)

        #expect(await eventually {
            (try? self.jsonObject(at: url))?["replacement"] as? String == "Oh My Zsh!"
        })
        let rewritten = try jsonObject(at: url)
        let preserved = try #require(rewritten["fromANewerBuild"] as? [String: Any])
        #expect(preserved["caseSensitive"] as? Bool == true)
    }

    @Test("a Note loads from its file and is written back when the entry is saved again")
    func noteSurvivesARewrite() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let url = try writeRawSnapshot(
            """
            {"id":"\(id.uuidString)","isEnabled":true,\
            "lastUpdated":"2026-01-01T09:30:00.000Z",\
            "replacement":"Anya","phrases":[],"note":"my sister"}
            """,
            id: id,
            into: root
        )

        let store = try await makeStore(root: root)
        var loaded = try #require(store.substitutions.first)
        #expect(loaded.note == "my sister")
        loaded.replacement = "Anja"
        store.upsert(loaded)

        #expect(await eventually {
            (try? self.jsonObject(at: url))?["replacement"] as? String == "Anja"
        })
        #expect(try jsonObject(at: url)["note"] as? String == "my sister")
    }
}
