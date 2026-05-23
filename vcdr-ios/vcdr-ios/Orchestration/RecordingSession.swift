import Foundation
import FluidAudio

@MainActor
final class RecordingSessionContext {
    let conversationID: UUID
    let streaming: StreamingAsrManager
    let setupTask: Task<Void, Error>
    var updateTask: Task<Void, Never>?

    init(
        conversationID: UUID,
        streaming: StreamingAsrManager,
        setupTask: Task<Void, Error>
    ) {
        self.conversationID = conversationID
        self.streaming = streaming
        self.setupTask = setupTask
    }

    func cancel() {
        updateTask?.cancel()
        setupTask.cancel()
    }
}

@MainActor
enum RecordingSession {
    case starting(RecordingSessionContext)
    case recording(RecordingSessionContext)
    case stopping(RecordingSessionContext)

    var context: RecordingSessionContext {
        switch self {
        case .starting(let context), .recording(let context), .stopping(let context):
            context
        }
    }
}
