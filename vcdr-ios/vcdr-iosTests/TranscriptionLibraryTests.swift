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
        #expect(env.state(of: .parakeetUltra) == .installed(bytes: 2048))
        #expect(env.state(of: .parakeetUltra)?.label(for: .parakeetUltra).localizedCaseInsensitiveContains("2 kb") == true)
        #expect(env.state(of: .whisperTiny) == .notInstalled)
    }

    /// The path a person takes when they install a model from the Library: the
    /// Install button starts the download, the row narrates it while it runs,
    /// and the model ends up installed and loaded without the screen being
    /// reopened.
    @Test("A model installed from the Library downloads, narrates itself and reaches ready")
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
            guard case .downloading(let progress) = env.state(of: .parakeetUltra) else { return false }
            return progress.fraction == nil && progress.label.hasPrefix("Downloading model")
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()
        #expect(await waitFor { env.state(of: .whisperTiny) == .ready(bytes: 1024) })
        #expect(env.state(of: .whisperTiny)?.label(for: .whisperTiny).localizedCaseInsensitiveContains("1 kb") == true)

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
            env.state(of: .whisperTiny)?.label(for: .whisperTiny).hasPrefix("Loading model · ") == true
        })
    }

    @Test("A model select offers what is installed, plus the value it already holds")
    func selectOffersInstalledModelsAndItsOwnValue() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        // The Default names Parakeet, and this phone does not have it.
        #expect(TranscriptionSettings.defaultModel == .parakeetUltra)
        #expect(env.state(of: .parakeetUltra) == .notInstalled)

        // The Default Model select: what is here, and what it is already
        // showing — dropping the latter would repoint the Default silently.
        #expect(env.library.selectableModels(holding: .parakeetUltra) == [.parakeetUltra, .whisperTiny])

        // A Prompt Mode's select, pinning nothing of its own, offers only what
        // is here.
        #expect(env.library.selectableModels(holding: nil) == [.whisperTiny])
    }

    @Test("Choosing a Default and pinning a model on a Prompt Mode both install nothing")
    func pickingAModelInstallsNothing() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        // The only model this phone has is the one about to be picked — which
        // is the only kind the selects offer it.
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let before = env.library.entries.map(\.state)

        env.defaults.set(TranscriptionModel.whisperTiny.rawValue, forKey: TranscriptionSettings.defaultModelKey)
        let override = env.library.override(.none, pinnedTo: .whisperTiny)

        #expect(override.model == .whisperTiny)
        // Two reads' worth of chances for an install to have started.
        await env.library.refresh()
        await env.library.refresh()
        #expect(env.library.entries.map(\.state) == before)
        #expect(await env.whisper.preparationsBegun == 0)
        #expect(await env.parakeet.preparationsBegun == 0)
    }

    @Test("A phone whose Library is empty installs the shipped Default once, and one with a model installed does not")
    func emptyLibraryInstallsTheDefaultOnce() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        // A later launch on a phone whose Default was deleted from under the
        // app: it still has a model to record with, so nothing is fetched
        // unasked.
        env.installFiles(for: env.whisper, bytes: 1024)
        #expect(await waitFor { env.state(of: .whisperTiny) == .installed(bytes: 1024) })

        env.library.installDefaultIfLibraryIsEmpty()

        await env.library.refresh()
        await env.library.refresh()
        #expect(await env.parakeet.preparationsBegun == 0)

        // The same phone with nothing installed at all: the shipped Default is
        // the one install the app makes on its own behalf, and asking twice
        // still downloads it once.
        #expect(await env.library.remove(.whisperTiny) == nil)
        env.library.installDefaultIfLibraryIsEmpty()
        env.library.installDefaultIfLibraryIsEmpty()

        #expect(await waitFor { await env.parakeet.preparationsBegun == 1 })
        env.installFiles(for: env.parakeet, bytes: 2048)
        await env.parakeet.becomeReady()
        #expect(await waitFor { env.state(of: .parakeetUltra) == .ready(bytes: 2048) })
        #expect(await env.parakeet.preparationsBegun == 1)
    }

    @Test("A model that is not the Default can be removed, and what it was told survives")
    func removesNonDefaultModel() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let toldBefore = TranscriptionSettings.settings(for: .whisper)

        // Nothing pins it, so there is nothing to disclose and no consent to
        // gather: the press removes it.
        #expect(env.library.pinnedModelRemoval(for: .whisperTiny) == nil)
        #expect(await env.library.remove(.whisperTiny) == nil)

        #expect(env.state(of: .whisperTiny) == .notInstalled)
        #expect(await env.whisper.isInstalled == false)
        #expect(env.state(of: .parakeetUltra) == .installed(bytes: 1024))
        #expect(TranscriptionSettings.settings(for: .whisper) == toldBefore)
    }

    @Test("Removing the Default Model is refused, and says why")
    func refusesToRemoveTheDefault() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        await env.library.refresh()
        #expect(TranscriptionSettings.defaultModel == .parakeetUltra)

        let refusal = await env.library.remove(.parakeetUltra)

        #expect(refusal == .isDefaultModel)
        #expect(refusal?.message.contains("Default Model") == true)
        #expect(await env.parakeet.isInstalled)
        #expect(env.state(of: .parakeetUltra) == .installed(bytes: 1024))
    }

    @Test("Removing a model Prompt Modes pin discloses those modes, the model and what they will use instead — and until it is agreed to, removes nothing")
    func pinnedRemovalDisclosesBothEndsAndWaits() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        env.pin(.whisperTiny, on: .dictation)
        env.pin(.whisperTiny, on: .verbatim)

        let removal = env.library.pinnedModelRemoval(for: .whisperTiny)

        #expect(removal?.pinningModes == [AIPromptMode.verbatim.displayName,
                                          AIPromptMode.dictation.displayName])
        #expect(removal?.disclosure == "AI off and AI on pin Whisper Tiny. "
            + "Remove it and they will use Parakeet Ultra (the Default Model).")
        // Declining is having read it and stopped here: nothing has moved.
        #expect(await env.whisper.isInstalled)
        #expect(TranscriptionSettings.override(for: .dictation).model == .whisperTiny)
    }

    @Test("Agreeing to a pinned removal deletes the model and unpins those Prompt Modes, which then follow the Default")
    func agreeingUnpinsAndLeavesTheModesOnTheDefault() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        var pinned = TranscriptionOverride.none
        pinned.model = .whisperTiny
        pinned[.whisper].languageHint = .russian
        TranscriptionSettings.setOverride(pinned, for: .dictation)
        env.pin(.whisperTiny, on: .verbatim)

        #expect(await env.library.remove(.whisperTiny) == nil)

        #expect(await env.whisper.isInstalled == false)
        #expect(AIPromptMode.allCases.allSatisfy { TranscriptionSettings.override(for: $0).model == nil })
        // The unpin cleared the model and nothing else it carried, and it is on
        // the phone rather than in this launch's memory.
        #expect(TranscriptionSettings.override(for: .dictation)[.whisper].languageHint == .russian)
        #expect(env.relaunched().pinnedModelRemoval(for: .whisperTiny) == nil)

        // Those modes follow the Default now, and move with it.
        #expect(TranscriptionSettings.effectiveTranscription(for: .dictation).model == .parakeetUltra)
        env.defaults.set(TranscriptionModel.whisperTiny.rawValue,
                         forKey: TranscriptionSettings.defaultModelKey)
        #expect(TranscriptionSettings.effectiveTranscription(for: .dictation).model == .whisperTiny)
    }

    @Test("An installability answer survives a relaunch, and one that never arrived leaves nothing behind")
    func remembersDefiniteAnswersAcrossLaunches() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let offline = URLError(.notConnectedToInternet)
        await env.whisper.setInstallability(supported: false)
        await env.parakeet.setInstallability(error: offline)

        await env.library.refresh()
        #expect(env.state(of: .whisperTiny) == .unsupported)
        #expect(env.state(of: .parakeetUltra) == .installabilityUnknown)

        // A second launch on a phone that can no longer reach the backend: the
        // answer it was given is drawn from what it already knows, and the one
        // that never arrived is still the row honest about not knowing.
        await env.whisper.setInstallability(error: offline)
        let relaunched = env.relaunched()
        await relaunched.refresh()

        #expect(relaunched.entry(for: .whisperTiny).state == .unsupported)
        #expect(relaunched.entry(for: .parakeetUltra).state == .installabilityUnknown)
        // This phone's own fact: nothing about it travels to another device.
        #expect(SharedConstants.sharedDefaults.object(forKey: ModelInstallabilityCache.storageKey) == nil)
    }

    @Test("A remembered answer is asked again at the next launch, and a wrong one is replaced")
    func asksAbsentModelsAgainAtLaunch() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.whisper.setInstallability(supported: false)
        await env.library.refresh()
        #expect(env.state(of: .whisperTiny) == .unsupported)

        // The backend now publishes a build this phone can run. Nobody reopens
        // the screen: the launch read alone turns the row into an offer.
        await env.whisper.setInstallability(supported: true)
        let corrected = env.relaunched()
        await corrected.refresh()
        #expect(corrected.entry(for: .whisperTiny).state == .notInstalled)
        #expect(corrected.entry(for: .whisperTiny).state.installTitle == "Install")

        // And a yes is remembered the way the no was: offline from here on, the
        // Install button is still on the row.
        await env.whisper.setInstallability(error: URLError(.notConnectedToInternet))
        let offlineLaunch = env.relaunched()
        await offlineLaunch.refresh()
        #expect(offlineLaunch.entry(for: .whisperTiny).state == .notInstalled)
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
    /// What this phone remembered about installability before the test, kept
    /// for the same reason.
    private let rememberedBefore: [String: Any]?

    /// Builds the Library the way the app builds it, so a test can ask for a
    /// second one over the same phone.
    private let makeLibrary: @MainActor () -> TranscriptionLibrary

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
        parakeet = providers[.parakeetUltra]!
        whisper = providers[.whisperTiny]!
        let defaults = defaults
        namingBefore = Dictionary(
            uniqueKeysWithValues: Self.namingKeys.map { ($0, defaults.string(forKey: $0)) }
        )
        for key in Self.namingKeys {
            defaults.removeObject(forKey: key)
        }
        rememberedBefore = defaults.dictionary(forKey: ModelInstallabilityCache.storageKey)
        defaults.removeObject(forKey: ModelInstallabilityCache.storageKey)
        // Built last: the Library reads what this phone remembers as it is
        // made, so it must be made on a phone that remembers nothing.
        let make: @MainActor () -> TranscriptionLibrary = {
            TranscriptionLibrary(
                models: TranscriptionProviderRegistry.offeredModels,
                provider: { providers[$0]! }
            )
        }
        makeLibrary = make
        library = make()
    }

    /// The same phone on a later launch: a new Library over the same providers,
    /// holding nothing of what the first one read.
    func relaunched() -> TranscriptionLibrary {
        makeLibrary()
    }

    private static let namingKeys: [String] = [TranscriptionSettings.defaultModelKey]
        + AIPromptMode.allCases.map(TranscriptionSettings.modeOverrideKey(for:))

    /// Pins `model` on `mode`, the way that mode's own screen would.
    func pin(_ model: TranscriptionModel, on mode: AIPromptMode) {
        var override = TranscriptionSettings.override(for: mode)
        override.model = model
        TranscriptionSettings.setOverride(override, for: mode)
    }

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
        if let rememberedBefore {
            defaults.set(rememberedBefore, forKey: ModelInstallabilityCache.storageKey)
        } else {
            defaults.removeObject(forKey: ModelInstallabilityCache.storageKey)
        }
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
