import Foundation

/// What one Recording Run's capture tap actually handed downstream: how many
/// buffers, how many frames, the loudest buffer, and when audio first arrived.
///
/// Counting happens inside the tap callback on the audio render thread, so
/// every operation here is plain arithmetic on already-computed values — no
/// allocation, no locking, no second walk over the samples.
nonisolated struct CaptureTally {
    private(set) var buffers = 0
    private(set) var frames = 0
    private(set) var peakLevel: Float = 0
    private(set) var firstBufferAt: Date?

    mutating func record(frames frameCount: Int, level: Float) {
        if firstBufferAt == nil { firstBufferAt = Date() }
        buffers += 1
        frames += frameCount
        peakLevel = max(peakLevel, level)
    }

    /// The capture half of the pair of pipeline lines. `firstBuffer` is stamped
    /// in the log file's own timestamp format, which is what lets this line be
    /// lined up against the streaming session's line without either component
    /// knowing about the other.
    var summary: String {
        let firstBuffer = firstBufferAt.map(LogBuffer.timestamp) ?? "none"
        return "buffers=\(buffers) frames=\(frames) peak=\(AudioLevelMeter.format(level: peakLevel)) firstBuffer=\(firstBuffer)"
    }
}
