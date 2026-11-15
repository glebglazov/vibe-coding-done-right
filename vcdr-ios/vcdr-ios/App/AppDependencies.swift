import AppIntents
import UIKit

/// The iOS composition root: it builds the one object graph, so a scene and a
/// scene-less intent launch reach the same instances. `AppDelegate` owns it,
/// because a delegate exists for every launch.
@MainActor
final class AppDependencies {
    let coordinator: RecordingFlowCoordinator
    let conversationReprocessor: any ConversationReprocessor
    let boot: AppBoot
    let hostAppSource: any HostAppSource
    let hostReturn: HostReturn
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
        let backgroundTasks = UIKitBackgroundTaskRunner()
        let historyWrites = HistoryStoreProxy()
        coordinator = RecordingFlowCoordinator(
            presence: card,
            keyboardChannel: keyboard,
            recordingEngine: engine,
            hotMicSession: hotMicSession,
            backgroundTasks: backgroundTasks,
            historyWrites: historyWrites,
            discardedRunFinalizer: HistoryDiscardedRunFinalizer(
                history: historyWrites,
                backgroundTasks: backgroundTasks
            )
        )
        conversationReprocessor = AIConversationReprocessor(
            history: historyWrites,
            backgroundTasks: backgroundTasks,
            substitutions: { [coordinator] in coordinator.substitutionStore.substitutions }
        )
        boot = AppBoot(steps: .coldLaunch(of: coordinator))
        remote = IntentRecordingRemote(boot: boot, coordinator: coordinator, card: card)
        hostAppSource = RemoteKeyboardsHostAppSource(ownBundleID: Bundle.main.bundleIdentifier ?? "")
        hostReturn = HostReturn(
            source: hostAppSource,
            runProgress: { [coordinator] in coordinator.hostReturnRunProgress },
            openApp: HostAppLauncher.open
        )
    }

    /// Makes the remote what `@AppDependency` resolves to in every intent.
    /// Runs from `AppDelegate.init`, before any intent can perform.
    func registerForAppIntents() {
        let remote = remote
        AppDependencyManager.shared.add(dependency: remote as any RecordingRunRemote)
    }
}
