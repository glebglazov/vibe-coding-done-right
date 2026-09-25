import Foundation
import OSLog

/// The launch sequence, callable from a scene and from a scene-less intent
/// launch alike. Only the first `launch()` does anything, so a scene that
/// reconnects mid-run cannot publish idle over a live Recording Run.
@MainActor
final class AppBoot {
    struct Steps {
        /// Must finish before any Recording Run starts.
        let prefix: @MainActor () -> Void
        /// Nothing on the record path waits for it: history buffers successes
        /// and the Substitution proxy replays edits made before it is ready.
        let deferred: @MainActor () async -> Void
    }

    private let steps: Steps
    private var deferredTask: Task<Void, Never>?

    init(steps: Steps) {
        self.steps = steps
    }

    func launch() {
        guard deferredTask == nil else { return }
        steps.prefix()
        deferredTask = Task { await steps.deferred() }
    }
}

extension AppBoot.Steps {
    /// VCDR's cold launch.
    /// - Prefix: migrate pre-split legacy keys, drop leftover Session Settings,
    ///   re-read settings the coordinator cached before migration, return the
    ///   Keyboard Channel to idle, and listen for keyboard commands.
    /// - Deferred: History Bootstrap and the Substitutions bootstrap (their
    ///   stores open off the main actor), the AFM probe (its synchronous
    ///   accessor can block for tens of seconds on first launch), the Library
    ///   read and a Default install on an empty Library (`docs/adr/0023`),
    ///   automatic model init after the shell's grace period, the AI
    ///   capability flag the keyboard gates on, and the prompt fetch.
    static func coldLaunch(of coordinator: RecordingFlowCoordinator) -> AppBoot.Steps {
        AppBoot.Steps(
            prefix: {
                LegacySettingsMigrator.migrateIfNeeded()
                SessionSettings.clearAll()
                coordinator.refreshSettingsFromStorage()
                coordinator.cleanupStaleResults()
                coordinator.setupCommandListener()
                Logger.app.info("[LaunchProbe] boot prefix done")
            },
            deferred: {
                async let historyReady: Void = coordinator.bootstrapHistory()
                async let substitutionsReady: Void = coordinator.bootstrapSubstitutions()
                async let afmReady: Bool = AFMAvailabilityCache.shared.refresh()
                async let libraryReady: Void = coordinator.transcriptionLibrary.refresh()
                async let modelReady: Void = coordinator.initializeModelAutomatically()
                await historyReady
                await substitutionsReady
                await libraryReady
                coordinator.transcriptionLibrary.installDefaultIfLibraryIsEmpty()
                await modelReady
                _ = await afmReady
                DefaultSettings.setAIConfigured(AIProcessingSettings.hasAICapability)
                Task.detached {
                    await PromptFetcher.refreshIfNeeded()
                }
                Logger.app.info("[LaunchProbe] boot complete")
            }
        )
    }
}
