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
        #expect(env.state(of: .parakeetV3)?.label(for: .parakeetV3).localizedCaseInsensitiveContains("2 kb") == true)
        #expect(env.state(of: .whisperLargeV3Turbo) == .notInstalled)
    }

    @Test("Two models installed at once install one after the other, each showing its progress")
    func installShowsProgress() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        // Asking for both in the same breath would leave which one takes the
        // turn to the scheduler; the second press a person makes lands on a
        // queue that is already running, so the test starts them that way too.
        env.library.install(.whisperLargeV3Turbo, urgency: .unawaited)
        #expect(await waitFor { await env.whisper.hasTakenItsTurn })
        env.library.install(.parakeetV3, urgency: .unawaited)

        await env.whisper.beginDownload(progress: 0.5)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .downloading(.fraction(0.5)) })

        // The second model is not downloading beside the first: it is held
        // back, and its row says so rather than looking stalled.
        #expect(await waitFor {
            guard case .waitingItsTurn(let label) = env.state(of: .parakeetV3) else { return false }
            return label.hasPrefix("Waiting its turn")
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .ready(bytes: 1024) })

        // Its turn came the moment the first finished: the row stopped being a
        // queued one. A backend that reports no fraction still has to say it is
        // downloading, which is the elapsed wait rather than a percentage.
        #expect(await waitFor { env.state(of: .parakeetV3) == .notInstalled })
        await env.parakeet.beginDownload()
        #expect(await waitFor {
            guard case .downloading(let progress) = env.state(of: .parakeetV3) else { return false }
            return progress.fraction == nil && progress.label.hasPrefix("Downloading model")
        })

        // The Library never cancels a download — the bytes are paid for either
        // way — so Parakeet's held-open preparation is finished here rather
        // than outliving the test.
        await env.parakeet.becomeReady()
    }

    @Test("A model select offers what is installed, plus the value it already holds")
    func selectOffersInstalledModelsAndItsOwnValue() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        env.installFiles(for: env.whisper, bytes: 1024)
        await env.library.refresh()
        // The Default names Parakeet, and this Mac does not have it.
        #expect(env.settings.transcriptionSettings.defaultModel == .parakeetV3)
        #expect(env.state(of: .parakeetV3) == .notInstalled)

        // The Default Model select: what is here, and what it is already
        // showing — dropping the latter would repoint the Default silently.
        #expect(env.library.selectableModels(holding: .parakeetV3) == [.parakeetV3, .whisperLargeV3Turbo])

        // A Mode's select, naming nothing of its own, offers only what is here.
        #expect(env.library.selectableModels(holding: nil) == [.whisperLargeV3Turbo])
    }

    @Test("A Mac whose Library is empty installs the shipped Default, and one with a model installed does not")
    func emptyLibraryInstallsTheDefaultOnce() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let watching = Task { await env.library.watch() }
        defer { watching.cancel() }

        // A later launch on a Mac whose Default was deleted from under the app:
        // it still has a model to record with, so nothing is fetched unasked.
        env.installFiles(for: env.whisper, bytes: 1024)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .installed(bytes: 1024) })

        env.library.installDefaultIfLibraryIsEmpty()

        await env.library.refresh()
        await env.library.refresh()
        #expect(await env.parakeet.hasTakenItsTurn == false)

        // The same Mac with nothing installed at all: the shipped Default is
        // the one install the app makes on its own behalf.
        #expect(await env.library.remove(.whisperLargeV3Turbo) == nil)
        env.library.installDefaultIfLibraryIsEmpty()

        #expect(await waitFor { await env.parakeet.hasTakenItsTurn })
        env.installFiles(for: env.parakeet, bytes: 2048)
        await env.parakeet.becomeReady()
        #expect(await waitFor { env.state(of: .parakeetV3) == .ready(bytes: 2048) })
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

    @Test("An installability answer survives a relaunch, and one that never arrived leaves nothing behind")
    func remembersDefiniteAnswersAcrossLaunches() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        let offline = URLError(.notConnectedToInternet)
        await env.whisper.setInstallability(supported: false)
        await env.parakeet.setInstallability(error: offline)

        await env.library.refresh()
        #expect(env.state(of: .whisperLargeV3Turbo) == .unsupported)
        #expect(env.state(of: .parakeetV3) == .installabilityUnknown)

        // A second launch on a Mac that can no longer reach the backend: the
        // answer it was given is drawn from what it already knows, and the one
        // that never arrived is still the row honest about not knowing.
        await env.whisper.setInstallability(error: offline)
        let relaunched = env.relaunched()
        await relaunched.refresh()

        #expect(relaunched.entry(for: .whisperLargeV3Turbo).state == .unsupported)
        #expect(relaunched.entry(for: .parakeetV3).state == .installabilityUnknown)
    }

    @Test("A remembered answer is asked again at the next launch, and a wrong one is replaced")
    func asksAbsentModelsAgainAtLaunch() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.whisper.setInstallability(supported: false)
        await env.library.refresh()
        #expect(env.state(of: .whisperLargeV3Turbo) == .unsupported)

        // The backend now publishes a build this Mac can run. Nobody reopens
        // the screen: the launch read alone turns the row into an offer.
        await env.whisper.setInstallability(supported: true)
        let corrected = env.relaunched()
        await corrected.refresh()
        #expect(corrected.entry(for: .whisperLargeV3Turbo).state == .notInstalled)
        #expect(corrected.entry(for: .whisperLargeV3Turbo).state.installTitle == "Install")

        // And a yes is remembered the way the no was: offline from here on, the
        // Install button is still on the row.
        await env.whisper.setInstallability(error: URLError(.notConnectedToInternet))
        let offlineLaunch = env.relaunched()
        await offlineLaunch.refresh()
        #expect(offlineLaunch.entry(for: .whisperLargeV3Turbo).state == .notInstalled)
    }

    @Test("A failed download is reported on its own model and can be retried")
    func failedDownloadRetries() async {
        let env = LibraryEnvironment()
        defer { env.cleanup() }
        await env.library.refresh()

        env.library.install(env.whisper.model, urgency: .unawaited)
        await env.whisper.fail(.offline)
        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .failed(.offline) })
        #expect(env.state(of: .whisperLargeV3Turbo)?.installTitle == "Try Again")
        #expect(env.state(of: .parakeetV3) == .notInstalled)

        await env.whisper.prepareAgain()
        env.library.install(.whisperLargeV3Turbo, urgency: .unawaited)
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
            env.state(of: .whisperLargeV3Turbo)?.label(for: .whisperLargeV3Turbo).hasPrefix("Loading model · ") == true
        })

        env.installFiles(for: env.whisper, bytes: 1024)
        await env.whisper.becomeReady()

        #expect(await waitFor { env.state(of: .whisperLargeV3Turbo) == .ready(bytes: 1024) })
    }
}
