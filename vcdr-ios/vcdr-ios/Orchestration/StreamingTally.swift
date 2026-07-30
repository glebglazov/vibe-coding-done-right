import Foundation

/// What one Recording Run's streaming session yielded, what its drain task
/// actually fed the transcriber, and how far into the run the transcriber
/// became able to accept audio.
///
/// Yields and drains are counted separately because they diverge in exactly the
/// interesting cases: buffers stack up in the unbounded stream while the model
/// loads, and a cancelled run leaves the tail undrained.
nonisolated struct StreamingTally {
    private(set) var buffersYielded = 0
    private(set) var buffersDrained = 0
    private(set) var framesDrained = 0
    private(set) var peakDrainedLevel: Float = 0

    private var firstYieldAt: ContinuousClock.Instant?
    private var transcriberStarted = false
    /// How long after the first captured buffer the transcriber finished
    /// starting. Nil means it was already up before any audio arrived — or,
    /// when `transcriberStarted` is false, that it never came up at all.
    private var transcriberStartupLag: Duration?

    mutating func recordYield() {
        if firstYieldAt == nil { firstYieldAt = .now }
        buffersYielded += 1
    }

    mutating func recordDrained(frames: Int, level: Float) {
        buffersDrained += 1
        framesDrained += frames
        peakDrainedLevel = max(peakDrainedLevel, level)
    }

    mutating func recordTranscriberStarted() {
        transcriberStarted = true
        guard let firstYieldAt else { return }
        transcriberStartupLag = firstYieldAt.duration(to: .now)
    }

    var summary: String {
        let readiness: String
        if !transcriberStarted {
            // Model load threw, or the run ended before it finished — the
            // buffers had nowhere to go.
            readiness = "never started"
        } else if let lag = transcriberStartupLag {
            readiness = "+\(Self.format(lag)) after first buffer"
        } else {
            readiness = "before first buffer"
        }
        return "yielded=\(buffersYielded) drained=\(buffersDrained) frames=\(framesDrained) "
            + "peak=\(AudioLevelMeter.format(level: peakDrainedLevel)) transcriberReady=\(readiness)"
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }
}
