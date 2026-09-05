import Foundation
import FoundationModels

/// One call to the on-device Apple Foundation Model, as a command.
///
/// The eval arms all speak HTTP; AFM has no endpoint, so this stands in for one.
/// It reads `{"system": ..., "user": ...}` on stdin and writes `{"text": ...}` on
/// stdout, or `{"error": ...}` and a non-zero exit. `--probe` skips the call and
/// reports only what the device says about the model, which is what the run
/// manifest records as the runtime.
@main
struct AFMShim {
    /// The caller sends the sampling too, so the settings the run manifest
    /// records are the settings the model was given rather than a second copy of
    /// them that can drift.
    struct Request: Decodable {
        let system: String
        let user: String
        let maximumResponseTokens: Int
    }

    static func main() async {
        if CommandLine.arguments.contains("--probe") {
            emit(["availability": availability()])
            return
        }
        do {
            let request = try JSONDecoder().decode(
                Request.self, from: FileHandle.standardInput.readDataToEndOfFile()
            )
            let session = LanguageModelSession { request.system }
            // Greedy, because a recorded run has to be re-recordable: the
            // temperature knob alone still leaves this model free to vary.
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: request.maximumResponseTokens
            )
            let response = try await session.respond(to: request.user, options: options)
            emit(["text": response.content, "availability": availability()])
        } catch {
            emit(["error": "\(error)"])
            exit(1)
        }
    }

    /// Why a call would fail before it is made — an Apple Intelligence switch
    /// that is off reads the same as a model that answered badly, unless the run
    /// says which it was.
    static func availability() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        @unknown default:
            return "unknown"
        }
    }

    static func emit(_ payload: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        FileHandle.standardOutput.write(data)
    }
}
