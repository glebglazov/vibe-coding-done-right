import AVFoundation
import Foundation
import WhisperKit

/// Turns the audio tap's buffers into the 16 kHz mono samples Whisper decodes,
/// keeping its converter across them: a rate converter carries state between
/// buffers, and a fresh one per buffer would put a seam at every boundary.
///
/// An object of its own because the conversion has to happen outside the live
/// session's actor — an `AVAudioPCMBuffer` is not `Sendable` and cannot cross
/// into one. Only the drain task calls this, one buffer at a time and in order,
/// which is what makes the unguarded converter safe.
final class WhisperRateSampler: @unchecked Sendable {
    private var toWhisperRate: AVAudioConverter?

    func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let resampled = resampled(buffer) else { return [] }
        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    private func resampled(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if toWhisperRate?.inputFormat != buffer.format {
            guard let whisperFormat = AVAudioFormat(
                standardFormatWithSampleRate: Double(WhisperKit.sampleRate),
                channels: 1
            ) else { return nil }
            toWhisperRate = AVAudioConverter(from: buffer.format, to: whisperFormat)
        }
        guard let toWhisperRate else { return nil }
        return try? AudioProcessor.resampleBuffer(buffer, with: toWhisperRate)
    }
}
