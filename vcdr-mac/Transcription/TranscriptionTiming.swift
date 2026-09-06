import AVFoundation
import Foundation

/// How long a finished transcription took against how long its audio was,
/// phrased once so Whisper and Parakeet put it on the record identically and
/// the numbers are comparable across families. A failed attempt is worded as
/// a failure, not as a slow success — nothing here lets an error masquerade
/// as a duration.
enum TranscriptionTiming {

    /// The length of the audio a model was asked to transcribe, read the way
    /// `AudioRecorder`'s own silence padding already reads a file's frame
    /// count and sample rate. A file this provider cannot even open is not
    /// worth failing the transcription over, so it reads as no time at all
    /// rather than as an error of its own.
    static func audioDuration(of audioFileURL: URL) -> Duration {
        guard let file = try? AVAudioFile(forReading: audioFileURL), file.fileFormat.sampleRate > 0 else {
            return .zero
        }
        return .seconds(Double(file.length) / file.fileFormat.sampleRate)
    }

    static func succeededLine(
        model: TranscriptionModel,
        audioDuration: Duration,
        elapsed: Duration,
        characterCount: Int
    ) -> String {
        "\(model.displayName) transcribed \(audioDuration) of audio in \(elapsed) (\(characterCount) chars)"
    }

    static func failedLine(
        model: TranscriptionModel,
        audioDuration: Duration,
        elapsed: Duration,
        error: Error
    ) -> String {
        "\(model.displayName) failed to transcribe \(audioDuration) of audio after \(elapsed): \(error)"
    }
}
