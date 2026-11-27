import Foundation
import OSLog

@MainActor
final class AppBoot {
    struct Steps {
        let prefix: @MainActor () -> Void
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
    static func coldLaunch(of coordinator: RecordingFlowCoordinator) -> AppBoot.Steps {
        AppBoot.Steps(
            prefix: {
                LegacySettingsMigrator.migrateIfNeeded()
                coordinator.refreshSettingsFromStorage()
                coordinator.keyboardWire.publishLaunch()
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
