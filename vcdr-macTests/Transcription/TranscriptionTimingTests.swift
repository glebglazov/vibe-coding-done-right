import AVFoundation
import Foundation
import Testing
@testable import vcdr_mac

@Suite("A transcription's timing")
struct TranscriptionTimingTests {

    private func makeAudioFile(seconds: Double, sampleRate: Double = 16000) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vcdr-timing-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try! AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try! file.write(from: buffer)
        return url
    }

    @Test("A recording's length comes from its own frame count and sample rate")
    func audioDurationReadsTheFile() {
        let url = makeAudioFile(seconds: 2, sampleRate: 16000)
        defer { try? FileManager.default.removeItem(at: url) }

        let duration = TranscriptionTiming.audioDuration(of: url)

        #expect(duration == .seconds(2))
    }

    @Test("A file that cannot be opened reads as no time at all, not as an error")
    func unreadableFileIsZero() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "vcdr-timing-missing-\(UUID().uuidString).caf")

        #expect(TranscriptionTiming.audioDuration(of: missing) == .zero)
    }

    @Test("A finished transcription names its model, the audio length and how long it took")
    func succeededLineNamesModelAndDurations() {
        let line = TranscriptionTiming.succeededLine(
            model: .whisperTiny,
            audioDuration: .seconds(3),
            elapsed: .milliseconds(500),
            characterCount: 42
        )

        #expect(line.contains("Whisper Tiny"))
        #expect(line.contains("42"))
    }

    @Test("A failed transcription reads as a failure, not as a slow success")
    func failedLineIsDistinguishableFromSucceeded() {
        let sameNumbers = (model: TranscriptionModel.parakeetV3, audioDuration: Duration.seconds(10), elapsed: Duration.seconds(10))
        let succeeded = TranscriptionTiming.succeededLine(
            model: sameNumbers.model,
            audioDuration: sameNumbers.audioDuration,
            elapsed: sameNumbers.elapsed,
            characterCount: 0
        )
        let failed = TranscriptionTiming.failedLine(
            model: sameNumbers.model,
            audioDuration: sameNumbers.audioDuration,
            elapsed: sameNumbers.elapsed,
            error: TranscriptionError.providerUnavailable
        )

        #expect(succeeded != failed)
        #expect(failed.contains("failed"))
        #expect(!succeeded.contains("failed"))
    }
}
