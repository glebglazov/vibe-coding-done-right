import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// What a device finds when it asks the model root where Parakeet is. Someone
/// upgrading has 461 MB sitting where FluidAudio put it and must not pay for it
/// again, and the answer has to be the same on every launch after that. One
/// source tree compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@Suite("Transcription model root")
struct TranscriptionModelRootTests {

    private let folderName = "parakeet-tdt-0.6b-v3-coreml"

    /// A fresh temporary directory to hold both the SDK's cache and the root,
    /// so neither test touches the paths the app really uses.
    private func makeScratch() -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-model-root-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func makeModelDirectory(at url: URL, weights: String) {
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try! weights.write(to: url.appendingPathComponent("Encoder.mlmodelc"), atomically: true, encoding: .utf8)
    }

    private func weights(in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"), encoding: .utf8)
    }

    @Test("an existing download moves into the root instead of being fetched again")
    func adoptsAnExistingDownload() {
        let scratch = makeScratch()
        let existing = scratch.appendingPathComponent(folderName, isDirectory: true)
        let root = scratch.appendingPathComponent("models", isDirectory: true)
        makeModelDirectory(at: existing, weights: "the 461 MB")

        let directory = TranscriptionModelRoot.adopting(existing, into: root)

        #expect(directory == root.appendingPathComponent(folderName, isDirectory: true))
        #expect(weights(in: directory) == "the 461 MB")
        #expect(!FileManager.default.fileExists(atPath: existing.path))
    }

    @Test("a second launch leaves the root as the first one left it")
    func isIdempotent() {
        let scratch = makeScratch()
        let existing = scratch.appendingPathComponent(folderName, isDirectory: true)
        let root = scratch.appendingPathComponent("models", isDirectory: true)
        makeModelDirectory(at: existing, weights: "the 461 MB")
        _ = TranscriptionModelRoot.adopting(existing, into: root)

        let directory = TranscriptionModelRoot.adopting(existing, into: root)

        #expect(weights(in: directory) == "the 461 MB")
    }

    @Test("no existing download leaves an empty root to download into")
    func fallsThroughWhenNothingWasDownloaded() {
        let scratch = makeScratch()
        let existing = scratch.appendingPathComponent(folderName, isDirectory: true)
        let root = scratch.appendingPathComponent("models", isDirectory: true)

        let directory = TranscriptionModelRoot.adopting(existing, into: root)

        #expect(directory == root.appendingPathComponent(folderName, isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}
