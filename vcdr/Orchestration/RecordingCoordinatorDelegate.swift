import Foundation

@MainActor
protocol RecordingCoordinatorDelegate: AnyObject {
    func recordingCoordinatorWillStartRecording()
    func recordingCoordinatorIsPanelVisible() -> Bool
    func recordingCoordinatorDidStartRecording(isFollowUp: Bool)
    func recordingCoordinatorDidStartTranscribing()
    func recordingCoordinatorDidCompleteRecording(result: RecordingResult)
    func recordingCoordinatorDidFailTranscription(isFollowUp: Bool)
    func recordingCoordinatorDidCancelRecording(wasFollowUp: Bool, wasFreshPill: Bool)
    func recordingCoordinatorDidFailRecording(message: String)
    func recordingCoordinatorDidRejectInput()
    func recordingCoordinatorDidCaptureSelection()
    func recordingCoordinatorDidCaptureClipboard()
}
