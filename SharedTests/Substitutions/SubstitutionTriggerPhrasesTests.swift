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
    func previousBuildFileLoads() throws {
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

        let store = FileSubstitutionStore(snapshot: FileSubstitutionStore.loadSnapshot(storageRoot: root))

        let loaded = try #require(store.substitutions.first)
        #expect(store.substitutions.count == 1)
        #expect(loaded.triggerPhrases == ["oh my zsh"])
        #expect(loaded.replacement == "Oh My Zsh")
    }

    @Test("a file written by this build still carries the singular key, set to the first phrase")
    func writesTheSingularKeyForOlderReaders() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileSubstitutionStore(snapshot: FileSubstitutionStore.loadSnapshot(storageRoot: root))
        let entry = Substitution(triggerPhrases: ["power zha", "powerja"], replacement: "Powierża")
        store.upsert(entry)

        let url = root.appendingPathComponent("Substitutions", isDirectory: true)
            .appendingPathComponent("\(entry.id.uuidString).json")
        #expect(await eventually { FileManager.default.fileExists(atPath: url.path) })

        let written = try jsonObject(at: url)
        #expect(written["triggerPhrase"] as? String == "power zha")
        #expect(written["triggerPhrases"] as? [String] == ["power zha", "powerja"])
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

        let store = FileSubstitutionStore(snapshot: FileSubstitutionStore.loadSnapshot(storageRoot: root))
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
}
