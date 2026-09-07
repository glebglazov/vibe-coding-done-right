import Foundation
import Testing
@testable import vcdr_ios

@Suite("Installing and removing iOS Transcription Models", .serialized)
@MainActor
struct TranscriptionLibraryTests {

    @Test("The Library lists every model iOS offers, with the size of what is installed")
    func listsModelsAndSizes() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 2048)

        await env.library.refresh()

        #expect(env.library.entries.map(\.model) == TranscriptionProviderRegistry.offeredModels)
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 2048))
        #expect(env.state(of: .parakeetV3)?.label.localizedCaseInsensitiveContains("2 kb") == true)
        #expect(env.state(of: .whisperTiny) == .notInstalled)
    }

    /// The path a person takes when they choose a model they do not have yet:
    /// the choice starts the download, the row narrates it while it runs, and
    /// the model ends up installed and loaded without the screen being reopened.
    @Test("A model chosen before it is downloaded downloads, narrates itself and reaches ready")
    func installNarratesAndReachesReady() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        env.library.install(.whisperTiny)
        await env.whisper.beginDownload(progress: 0.5)
        #expect(await waitFor { env.state(of: .whisperTiny) == .downloading(.fraction(0.5)) })

        // A backend that reports no fraction still has to say it is
        // downloading, which is the elapsed wait rather than a percentage.
        await env.parakeet.beginDownload()
        #expect(await waitFor {
            guard case .downloading(let progress) = env.state(of: .parakeetV3) else { return false }
            return progress.fraction == nil && progress.label.hasPrefix("Downloading model")
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()
        #expect(await waitFor { env.state(of: .whisperTiny) == .ready(bytes: 1024) })
        #expect(env.state(of: .whisperTiny)?.label.localizedCaseInsensitiveContains("1 kb") == true)

        await env.parakeet.becomeReady()
    }

    /// A preparation the Library never started — the Default warming at launch
    /// — still has to move the row Settings shows for it.
    @Test("A preparation the Library never started still moves a row")
    func watchesAPreparationItDidNotStart() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        await env.whisper.beginLoading()

        #expect(await waitFor { env.state(of: .whisperTiny)?.isPreparing == true })
        // Past the heartbeat threshold the line has to carry the seconds spent,
        // which is how a slow load reads differently from a stuck one.
        #expect(await waitFor(timeout: .seconds(6)) {
            env.state(of: .whisperTiny)?.label.hasPrefix("Loading model · ") == true
        })
    }

    @Test("A model nothing names can be removed, and what it was told survives")
    func removesAModelNothingNames() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let toldBefore = TranscriptionSettings.settings(for: .whisper)

        #expect(await env.library.remove(.whisperTiny) == nil)

        #expect(env.state(of: .whisperTiny) == .notInstalled)
        #expect(await env.whisper.isInstalled == false)
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 1024))
        #expect(TranscriptionSettings.settings(for: .whisper) == toldBefore)
    }

    @Test("Removing the Default Model is refused, and says why")
    func refusesToRemoveTheDefault() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        await env.library.refresh()
        #expect(TranscriptionSettings.defaultModel == .parakeetV3)

        let refusal = await env.library.remove(.parakeetV3)

        #expect(refusal == .isDefaultModel)
        #expect(refusal?.message.contains("Default Model") == true)
        #expect(await env.parakeet.isInstalled)
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 1024))
    }

    @Test("Removing a model a Prompt Mode records with is refused, and names that mode")
    func refusesToRemoveAModelAModeNames() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        var override = TranscriptionOverride.none
        override.model = .whisperTiny
        env.defaults.set(override.rawValue,
                         forKey: TranscriptionSettings.modeOverrideKey(for: .dictation))

        let refusal = await env.library.remove(.whisperTiny)

        #expect(refusal == .namedByModes([AIPromptMode.dictation.displayName]))
        #expect(refusal?.message.contains("Dictation") == true)
        #expect(await env.whisper.isInstalled)
    }

    @Test("A model whose installability is not known yet still has a row that says so")
    func unknownInstallabilityIsARow() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.whisper.setInstallability(error: URLError(.notConnectedToInternet))

        await env.library.refresh()

        #expect(env.state(of: .whisperTiny) == .installabilityUnknown)

        // The next visit asks again, and a backend that answers "not on this
        // phone" is a different row from one that could not answer at all.
        await env.whisper.setInstallability(supported: false)
        await env.library.refresh()
        #expect(env.state(of: .whisperTiny) == .unsupported)
    }
}

/// A Library over providers whose preparation a test drives, each with its own
/// directory under a temp root — the same shape the real Library has, with the
/// download replaced by a test writing the files.
@MainActor
private struct LibraryEnvironment {
    let root = FileManager.default.temporaryDirectory.appending(path: "vcdr-library-\(UUID().uuidString)")
    let defaults = UserDefaults.standard
    let parakeet: FakeInstallableProvider
    let whisper: FakeInstallableProvider
    let library: TranscriptionLibrary

    /// What the Default and the Prompt Modes named before the test touched
    /// them: the Library reads this device's own settings, which every test in
    /// this process shares.
    private let namingBefore: [String: String?]

    init() {
        let root = root
        let providers = Dictionary(
            uniqueKeysWithValues: TranscriptionProviderRegistry.offeredModels.map { model in
                (model, FakeInstallableProvider(
                    model: model,
                    installedDirectory: root.appending(path: model.rawValue)
                ))
            }
        )
        parakeet = providers[.parakeetV3]!
        whisper = providers[.whisperTiny]!
        library = TranscriptionLibrary(
            models: TranscriptionProviderRegistry.offeredModels,
            provider: { providers[$0]! }
        )
        let defaults = defaults
        namingBefore = Dictionary(
            uniqueKeysWithValues: Self.namingKeys.map { ($0, defaults.string(forKey: $0)) }
        )
        for key in Self.namingKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static let namingKeys: [String] = [TranscriptionSettings.defaultModelKey]
        + AIPromptMode.allCases.map(TranscriptionSettings.modeOverrideKey(for:))

    func installFiles(for provider: FakeInstallableProvider, bytes: Int) {
        let directory = provider.installedDirectory
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data(repeating: 0, count: bytes).write(to: directory.appending(path: "weights.bin"))
    }

    func state(of model: TranscriptionModel) -> TranscriptionModelState? {
        library.entries.first { $0.model == model }?.state
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        for (key, value) in namingBefore {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

private func waitFor(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let start = ContinuousClock.now
    while start.duration(to: .now) < timeout {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}
