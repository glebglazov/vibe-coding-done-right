import Foundation
import OSLog

@MainActor
final class IntentRecordingRemote: RecordingRunRemote {
    private let boot: AppBoot
    private let coordinator: RecordingFlowCoordinator
    private let card: any RecordingRunPresence
    /// On iPhone the system stops a background recording without a card. The
    /// iPad records without one, so a missing card there is only logged.
    private let requiresCardToRecord: Bool

    init(
        boot: AppBoot,
        coordinator: RecordingFlowCoordinator,
        card: any RecordingRunPresence,
        requiresCardToRecord: Bool
    ) {
        self.boot = boot
        self.coordinator = coordinator
        self.card = card
        self.requiresCardToRecord = requiresCardToRecord
    }

    func toggleFromShortcut() async throws(RecordingRemoteRefusal) {
        boot.launch()
        switch RecordingToggle.command(for: coordinator.activeRunPhase) {
        case .ignore:
            Logger.recording.info("Toggle Recording ignored — a cancel or Finalizing is in flight")
        case .stop:
            Task { await coordinator.stopActiveRun() }
        case .start:
            try await startFromShortcut()
        }
    }

    func stopFromCard() async {
        boot.launch()
        guard RecordingToggle.stopCommand(for: coordinator.activeRunPhase) == .stop else { return }
        Task { await coordinator.stopActiveRun() }
    }

    private func startFromShortcut() async throws(RecordingRemoteRefusal) {
        guard coordinator.hasMicrophonePermission else { throw .microphoneNotAllowed }
        if !card.areActivitiesEnabled {
            guard !requiresCardToRecord else { throw .liveActivitiesOff }
            Logger.recording.warning("Toggle Recording starts without a card: Live Activities are off")
        }

        await coordinator.startRecording(origin: .shortcut)
        guard coordinator.activeRunPhase != nil, !(await card.isShowingCard()) else { return }
        guard !requiresCardToRecord else {
            Logger.recording.error("Toggle Recording discarded: ActivityKit refused the card")
            await coordinator.discardRecording()
            throw .cardUnavailable
        }
        Logger.recording.warning("Toggle Recording goes on without a card")
    }
}
