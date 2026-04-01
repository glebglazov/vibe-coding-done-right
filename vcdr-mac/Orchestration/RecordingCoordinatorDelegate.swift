import Foundation

@MainActor
protocol RecordingCoordinatorDelegate: AnyObject {
    func recordingCoordinatorWillStartRecording()
    func recordingCoordinatorDidStartRecording()
    func recordingCoordinatorDidStartTranscribing()
    func recordingCoordinatorDidCompleteRecording(result: RecordingResult)
    func recordingCoordinatorDidFailTranscription()
    func recordingCoordinatorDidCancelRecording()
    func recordingCoordinatorDidFailRecording(message: String)
    func recordingCoordinatorDidRejectInput()
    func recordingCoordinatorSelectionCaptureFinished(didCapture: Bool)
}
