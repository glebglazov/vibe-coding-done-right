import Foundation

/// The iOS composition root: it builds the one object graph, so a scene and a
/// scene-less intent launch reach the same instances. `AppDelegate` owns it,
/// because a delegate exists for every launch.
@MainActor
final class AppDependencies {
    let coordinator: RecordingFlowCoordinator
    let boot: AppBoot

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
            backgroundTasks: UIKitBackgroundTaskRunner()
        )
        boot = AppBoot(steps: .coldLaunch(of: coordinator))
    }
}
