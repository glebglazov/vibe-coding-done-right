import Foundation
import Testing
@testable import vcdr_mac

@Suite("Transcription Model Library")
@MainActor
struct TranscriptionLibraryTests {

    @Test("The Library lists every model the platform offers, with the size of what is installed")
    func listsModelsAndSizes() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 2048)

        await env.library.refresh()

        #expect(env.library.entries.map(\.model) == [.parakeetV3, .whisperLargeV3Turbo])
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 2048))
        #expect(env.state(of: .parakeetV3)?.label.localizedCaseInsensitiveContains("2 kb") == true)
        #expect(env.state(of: .whisperLargeV3Turbo) == .notInstalled)
    }

    @Test("Installing a model shows its progress and leaves it ready")
    func installShowsProgress() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        env.library.install(.whisperLargeV3Turbo)
        env.library.install(.parakeetV3)

        await env.whisper.beginDownload(progress: 0.5)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .downloading(.fraction(0.5)) })

        // A backend that reports no fraction still has to say it is downloading,
        // which is the elapsed wait rather than a percentage.
        await env.parakeet.beginDownload()
        #expect(await waitFor {
            guard case .downloading(let progress) = env.state(of: .parakeetV3) else { return false }
            return progress.fraction == nil && progress.label.hasPrefix("Downloading model")
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .ready(bytes: 1024) })

        // The Library never cancels a download — the bytes are paid for either
        // way — so Parakeet's held-open preparation is finished here rather
        // than outliving the test.
        await env.parakeet.becomeReady()
    }

    @Test("A model that is not the Default can be removed, and its settings survive")
    func removesNonDefaultModel() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        let settingsBefore = env.settings.transcriptionSettings

        #expect(await env.library.remove(.whisperLargeV3Turbo) == nil)

        #expect(env.state(of: .whisperLargeV3Turbo) == .notInstalled)
        #expect(await env.whisper.isInstalled == false)
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 1024))
        #expect(env.settings.transcriptionSettings == settingsBefore)
    }

    @Test("Removing the Default Model is refused, and says why")
    func refusesToRemoveTheDefault() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.parakeet, bytes: 1024)
        await env.library.refresh()
        #expect(env.settings.transcriptionSettings.defaultModel == .parakeetV3)

        let refusal = await env.library.remove(.parakeetV3)

        #expect(refusal == .isDefaultModel)
        #expect(refusal?.message.contains("Default Model") == true)
        #expect(await env.parakeet.isInstalled)
        #expect(env.state(of: .parakeetV3) == .installed(bytes: 1024))
    }

    @Test("A model whose installability is not known yet still has a row that says so")
    func unknownInstallabilityIsARow() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.whisper.setInstallability(error: URLError(.notConnectedToInternet))

        await env.library.refresh()

        #expect(env.library.entries.count == 2)
        #expect(env.state(of: .whisperLargeV3Turbo) == .installabilityUnknown)

        // The next visit asks again, and a backend that answers "not on this
        // Mac" is a different row from one that could not answer at all.
        await env.whisper.setInstallability(supported: false)
        await env.library.refresh()
        #expect(env.state(of: .whisperLargeV3Turbo) == .unsupported)
    }

    @Test("A failed download is reported on its own model and can be retried")
    func failedDownloadRetries() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.library.refresh()

        env.library.install(env.whisper.model)
        await env.whisper.fail(.offline)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .failed(.offline) })
        #expect(env.state(of: .whisperLargeV3Turbo)?.installTitle == "Try Again")
        #expect(env.state(of: .parakeetV3) == .notInstalled)

        await env.whisper.prepareAgain()
        env.library.install(.whisperLargeV3Turbo)
        env.installFiles(for: env.whisper, bytes: 512)
        await env.whisper.becomeReady()
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .ready(bytes: 512) })
    }

    @Test("A preparation the Library never started still moves a row, and the row reaches ready")
    func watchesAPreparationItDidNotStart() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        // What launch does with the Default: the provider prepares, and nothing
        // ever asks the Library to install it.
        await env.whisper.beginLoading()

        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo)?.isPreparing == true })
        // Past the heartbeat threshold the line has to carry the seconds spent,
        // which is how a slow load reads differently from a stuck one.
        #expect(await waitFor(timeout: .seconds(6)) {
            env.state(of: .whisperLargeV3Turbo)?.label.hasPrefix("Loading model · ") == true
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()

        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .ready(bytes: 1024) })
    }
}
