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
        let hotMicSession = HotMicSession(engine: engine, presence: HotMicActivityController(), keyboard: keyboard)
        coordinator = RecordingFlowCoordinator(
            keyboardChannel: keyboard,
            recordingEngine: engine,
            hotMicSession: hotMicSession,
            backgroundTasks: UIKitBackgroundTaskRunner()
        )
        boot = AppBoot(steps: .coldLaunch(of: coordinator))
    }
}
