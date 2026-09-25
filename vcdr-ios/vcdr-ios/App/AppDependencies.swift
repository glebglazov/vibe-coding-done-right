import AppIntents
import UIKit

/// The iOS composition root: it builds the one object graph, so a scene and a
/// scene-less intent launch reach the same instances. `AppDelegate` owns it,
/// because a delegate exists for every launch.
@MainActor
final class AppDependencies {
    let coordinator: RecordingFlowCoordinator
    let boot: AppBoot
    private let remote: IntentRecordingRemote

    init() {
        let engine = AudioRecorder()
        let keyboard = KeyboardChannel.live
        let card = MicPresenceCard(
            controller: HotMicActivityController(),
            clock: SystemHotMicClock(),
            now: Date.init
        )
        let hotMicSession = HotMicSession(engine: engine, presence: card, keyboard: keyboard)
        coordinator = RecordingFlowCoordinator(
            presence: card,
            keyboardChannel: keyboard,
            recordingEngine: engine,
            hotMicSession: hotMicSession,
            backgroundTasks: UIKitBackgroundTaskRunner(),
            pasteboard: GeneralPasteboard()
        )
        boot = AppBoot(steps: .coldLaunch(of: coordinator))
        remote = IntentRecordingRemote(
            boot: boot,
            coordinator: coordinator,
            card: card,
            requiresCardToRecord: UIDevice.current.userInterfaceIdiom == .phone
        )
    }

    /// Makes the remote what `@AppDependency` resolves to in both intents.
    /// Runs from `AppDelegate.init`, before any intent can perform.
    func registerForAppIntents() {
        let remote = remote
        AppDependencyManager.shared.add(dependency: remote as any RecordingRunRemote)
    }
}
