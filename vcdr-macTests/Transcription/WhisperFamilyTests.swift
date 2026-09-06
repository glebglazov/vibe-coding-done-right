import Foundation
import Testing
@testable import vcdr_mac

@Suite("The Whisper family on the Mac")
@MainActor
struct WhisperFamilyTests {

    /// The Whispers the Mac offers, over mock providers that each keep their
    /// files in a directory of their own — which is what a row reporting its
    /// own size rather than another's rests on.
    private struct Environment {
        let root = FileManager.default.temporaryDirectory.appending(path: "vcdr-whispers-\(UUID().uuidString)")
        let whispers = TranscriptionProviderRegistry.offeredModels.filter { $0.family == .whisper }
        let settings: AppSettings
        let providers: [TranscriptionModel: MockTranscriptionProvider]
        let library: TranscriptionLibrary

        init() {
            let root = root
            settings = AppSettings(
                userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!,
                secretStore: InMemorySecretStore()
            )
            providers = Dictionary(uniqueKeysWithValues: whispers.map { model in
                (model, MockTranscriptionProvider(
                    model: model,
                    isReady: false,
                    preparationPhase: .preparing,
                    installedDirectory: root.appending(path: model.rawValue)
                ))
            })
            let providers = providers
            library = TranscriptionLibrary(
                models: whispers,
                provider: { providers[$0]! },
                settings: settings
            )
        }

        /// Fills a model's own directory, so its row has a size no other model's
        /// files could account for.
        func installFiles(_ bytes: Int, for model: TranscriptionModel) {
            let directory = providers[model]!.installedDirectory
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try! Data(repeating: 0, count: bytes).write(to: directory.appending(path: "weights.bin"))
        }

        func state(of model: TranscriptionModel) -> TranscriptionModelState? {
            library.entries.first { $0.model == model }?.state
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Every Whisper installs, becomes the Default and is removed again, weighed by its own files")
    func everyWhisperInstallsAndRemoves() async {
        let env = Environment()
        defer { env.cleanup() }
        #expect(env.whispers.count > 1)

        // A size no other model shares, so a row showing another's would be a
        // number that cannot be confused for its own.
        let sizes = Dictionary(uniqueKeysWithValues: env.whispers.enumerated().map { ($1, 1024 * ($0 + 1)) })
        for whisper in env.whispers {
            env.installFiles(sizes[whisper]!, for: whisper)
        }
        await env.library.refresh()

        for whisper in env.whispers {
            #expect(env.state(of: whisper) == .installed(bytes: Int64(sizes[whisper]!)))
        }

        for whisper in env.whispers {
            env.settings.transcriptionSettings.defaultModel = whisper
            #expect(env.library.removalRefusal(for: whisper) == .isDefaultModel)

            env.settings.transcriptionSettings.defaultModel = .parakeetV3
            #expect(await env.library.remove(whisper) == nil)
            #expect(env.state(of: whisper) == .notInstalled)
        }
    }

    @Test("Only multilingual Whispers are offered, each with a checkpoint of its own")
    func onlyMultilingualWhispersAreOffered() {
        let offered = TranscriptionProviderRegistry.offeredModels.filter { $0.family == .whisper }

        #expect(offered == WhisperCheckpoint.allCases.map(\.model))
        // The English-only checkpoints argmax publishes beside these cannot
        // accept a Language Hint at all, so offering one would put a Whisper on
        // screen that the family's own settings do not reach.
        #expect(WhisperCheckpoint.allCases.allSatisfy { !$0.rawValue.contains(".en") })

        let directories = WhisperCheckpoint.allCases.map { WhisperProvider(checkpoint: $0).installedDirectory }
        #expect(Set(directories).count == WhisperCheckpoint.allCases.count)
    }
}
