import Foundation

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let modelName: String
    let recordingDuration: TimeInterval  // seconds
    let timestamp: Date
    let actionResult: String?  // stdout from bash action, nil for paste

    init(
        text: String,
        modelName: String,
        recordingDuration: TimeInterval,
        actionResult: String? = nil,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.text = text
        self.modelName = modelName
        self.recordingDuration = recordingDuration
        self.actionResult = actionResult
        self.timestamp = timestamp
    }

    /// Formats recording duration as "M:SS" (e.g. "0:03", "1:15")
    var formattedDuration: String {
        let totalSeconds = Int(recordingDuration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
