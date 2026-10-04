import Foundation
import OSLog

/// A Shortcut start always needs the card: AppIntents ends VCDR when an
/// `AudioRecordingIntent` leaves audio running without a Live Activity.
@MainActor
final class IntentRecordingRemote: RecordingRunRemote {
    private let boot: AppBoot
    private let coordinator: RecordingFlowCoordinator
    private let card: any RecordingRunPresence

    init(boot: AppBoot, coordinator: RecordingFlowCoordinator, card: any RecordingRunPresence) {
        self.boot = boot
        self.coordinator = coordinator
        self.card = card
    }

    func startFromShortcut() async throws(RecordingRemoteRefusal) {
        boot.launch()
        guard coordinator.activeRunPhase == nil else {
            Logger.recording.info("Start Recording ignored — a run is already in progress")
            return
        }
        guard coordinator.hasMicrophonePermission else { throw .microphoneNotAllowed }
        guard card.areActivitiesEnabled else { throw .liveActivitiesOff }

        switch await coordinator.startRecording(origin: .shortcut) {
        case .failed(let message): throw .runFailed(message)
        case .cancelledArming, .ignored: return
        case .capturing: break
        }

        let run = coordinator.activeRun?.run
        guard !(await card.isShowingCard()) else { return }
        // The card check suspends; the run it was made for may have ended, and
        // another may have started, by the time it answers.
        guard let active = coordinator.activeRun, active.run === run, case .capturing = active.phase else { return }
        Logger.recording.error("Start Recording discarded: ActivityKit refused the card")
        await coordinator.discardRecording()
        throw .cardUnavailable
    }

    func stopFromShortcut() async throws(RecordingRemoteRefusal) -> String {
        boot.launch()
        switch await coordinator.stopActiveRun() {
        case .finalized(.success(let success)): return success.finalText
        case .finalized(.processingFailure(let failure)): throw .runFailed(failure.message)
        case .finalized(.emptyResult): throw .noSpeech
        case .finalized(.cancellation), .cancelledArming: throw .runCancelled
        case .ignored, .noRun: throw .notRecording
        }
    }

    func stopFromCard() async {
        boot.launch()
        guard RecordingToggle.stopCommand(for: coordinator.activeRunPhase) == .stop else { return }
        Task { await coordinator.stopActiveRun() }
    }

    var isRecording: Bool {
        RecordingToggle.stopCommand(for: coordinator.activeRunPhase) == .stop
    }
}
