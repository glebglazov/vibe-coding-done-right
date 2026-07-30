import AVFoundation
import Foundation

/// Normalized 0.0–1.0 loudness of one PCM buffer.
///
/// Shared rather than duplicated because two independent readings are compared:
/// the capture tap measures the buffers it hands off, the streaming drain
/// measures the buffers the transcriber actually consumes. The comparison only
/// carries information if both readings walk the samples the same way and land
/// on the same scale.
nonisolated struct AudioLevelMeter {
    /// Floor value to avoid log10(0) when computing level from silent audio
    private static let silenceFloor: Float = 1e-7
    /// dB range mapped to 0.0–1.0 linear scale (matches AVAudioRecorder.averagePower range)
    private static let dbRange: Float = 60

    /// Takes the RMS of the first channel, maps it onto a 60 dB window, and
    /// bends that with a square root so ordinary speech occupies most of the
    /// 0–1 range instead of hugging the bottom.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))

        // RMS (Root Mean Square) for average loudness
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to dB-like scale, then normalize to 0–1
        let dB = 20 * log10(max(rms, silenceFloor))
        let linear = max(0, (dB + dbRange) / dbRange)
        // Square root curve expands the speech range into a wider visual range
        return sqrt(linear)
    }

    /// Fixed-width rendering so a tap-side peak and a drain-side peak can be
    /// compared by eye in the log.
    static func format(level: Float) -> String {
        String(format: "%.3f", level)
    }
}
