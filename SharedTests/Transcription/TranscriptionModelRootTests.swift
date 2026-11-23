import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// What the model root gives back once Parakeet Ultra has loaded. Someone
/// updating has Parakeet v3's ~470 MB on disk that nothing reads any more, and
/// the app must return it without touching anything else. One source tree
/// compiled into both `vcdr-macTests` and `vcdr-iosTests`.
@Suite("Transcription model root")
struct TranscriptionModelRootTests {

    /// A fresh temporary directory to hold the root and its neighbours, so no
    /// test touches the paths the app really uses.
    private func makeScratch() -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-model-root-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func makeModelDirectory(at url: URL) {
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try! "weights".write(to: url.appendingPathComponent("Encoder.mlmodelc"), atomically: true, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("Parakeet v3's folders go once Ultra has loaded, and Ultra and the Whispers stay")
    func removesWhatUltraReplaced() {
        let root = makeScratch().appendingPathComponent("models", isDirectory: true)
        let v3 = root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        let v3FromAnOlderSDK = root.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        let ultra = root.appendingPathComponent("parakeet-ultra", isDirectory: true)
        let whisper = root.appendingPathComponent("models/argmaxinc", isDirectory: true)
        for directory in [v3, v3FromAnOlderSDK, ultra, whisper] {
            makeModelDirectory(at: directory)
        }

        TranscriptionModelRoot.removeDownloads(replacedBy: .parakeetUltra, in: root)

        #expect(!exists(v3))
        #expect(!exists(v3FromAnOlderSDK))
        #expect(exists(ultra))
        #expect(exists(whisper))
    }

    @Test("a second removal finds nothing to do and changes nothing")
    func isIdempotent() {
        let root = makeScratch().appendingPathComponent("models", isDirectory: true)
        let ultra = root.appendingPathComponent("parakeet-ultra", isDirectory: true)
        makeModelDirectory(at: root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true))
        makeModelDirectory(at: ultra)
        TranscriptionModelRoot.removeDownloads(replacedBy: .parakeetUltra, in: root)

        TranscriptionModelRoot.removeDownloads(replacedBy: .parakeetUltra, in: root)

        #expect(try! FileManager.default.contentsOfDirectory(atPath: root.path) == ["parakeet-ultra"])
    }

    @Test("a v3 folder outside the model root is left where it is")
    func leavesEverythingOutsideTheRoot() {
        let scratch = makeScratch()
        let root = scratch.appendingPathComponent("models", isDirectory: true)
        let sdkCache = scratch.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        makeModelDirectory(at: sdkCache)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        TranscriptionModelRoot.removeDownloads(replacedBy: .parakeetUltra, in: root)

        #expect(exists(sdkCache))
    }

    @Test("a Whisper replaced nothing, so loading one removes nothing")
    func whisperRemovesNothing() {
        let root = makeScratch().appendingPathComponent("models", isDirectory: true)
        let v3 = root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        makeModelDirectory(at: v3)

        TranscriptionModelRoot.removeDownloads(replacedBy: .whisperLargeV3Turbo, in: root)

        #expect(exists(v3))
    }
}
