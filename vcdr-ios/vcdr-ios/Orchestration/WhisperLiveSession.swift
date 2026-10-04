import AVFoundation
import Foundation
import OSLog
import WhisperKit

/// Whisper's live view: the recording so far, decoded again every second or so,
/// folded into settled text and a volatile tail by `ChunkedRedecoding`
/// (`docs/adr/0022`). The transcript this session finishes with is that settled
/// text plus one last decode of the audio behind it, so what is delivered is
/// what the person watched settle.
actor WhisperLiveSession: RecordingStreamingSession {
    private let provider: WhisperProvider
    private let settings: TranscriptionModelSettings
    private let spellingHints: SpellingHints
    private let audio = CapturedAudioPipeline()

    /// Every sample captured so far, at the 16 kHz mono Whisper decodes. The
    /// whole recording is kept because every decode re-reads it from the last
    /// settled point rather than picking up where the previous one stopped.
    private var samples: [Float] = []
    private var samplesAtLastDecode = 0

    private var whisper: WhisperKit?
    private var redecoding = ChunkedRedecoding()
    private var redecodeTask: Task<Void, Never>?

    private let sampler = WhisperRateSampler()

    private let liveUpdates: AsyncStream<String>
    private let liveUpdatesInlet: AsyncStream<String>.Continuation

    init(provider: WhisperProvider, settings: TranscriptionModelSettings, spellingHints: SpellingHints) {
        self.provider = provider
        self.settings = settings
        self.spellingHints = spellingHints
        (liveUpdates, liveUpdatesInlet) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async throws {
        let whisper = try await provider.prepared()
        self.whisper = whisper
        audio.drain { [weak self, sampler] buffer in
            // Resampled out here, before the hop: an `AVAudioPCMBuffer` is not
            // `Sendable` and cannot cross into an actor, and the samples it
            // carries are.
            let samples = sampler.samples(from: buffer)
            await self?.absorb(samples)
        }
        redecodeTask = Task { [weak self] in
            await self?.redecodeWhileSpeaking()
        }
    }

    nonisolated func streamAudio(_ buffer: AVAudioPCMBuffer) {
        audio.yield(buffer)
    }

    func cancel() async {
        redecodeTask?.cancel()
        audio.cancel()
        liveUpdatesInlet.finish()
        audio.logTally(outcome: "cancelled")
    }

    func finish() async throws -> String {
        redecodeTask?.cancel()
        await audio.finishDraining()
        liveUpdatesInlet.finish()
        audio.logTally(outcome: "finalized")
        // The last decode holds nothing back: the recording has stopped, so
        // there is no wider window left that could rewrite its tail.
        let tail = try await decodeFromSettledPoint()
        return redecoding.transcript(endingWith: tail)
    }

    func liveTranscriptUpdates() async -> AsyncStream<String> {
        liveUpdates
    }

    // MARK: - Capture

    private func absorb(_ captured: [Float]) {
        samples.append(contentsOf: captured)
    }

    // MARK: - Chunked re-decoding

    /// Re-decodes while the recording runs, waiting until enough new audio has
    /// arrived to be worth the pass. A decode of barely-changed audio costs the
    /// same as a decode of a whole new sentence and tells the view nothing new.
    private func redecodeWhileSpeaking() async {
        while !Task.isCancelled {
            guard samples.count - samplesAtLastDecode >= Self.samplesPerDecode else {
                try? await Task.sleep(for: Self.pollInterval)
                continue
            }
            samplesAtLastDecode = samples.count
            do {
                let decoded = try await decodeFromSettledPoint()
                liveUpdatesInlet.yield(redecoding.absorb(decoded).text)
            } catch {
                // A decode that fails mid-recording costs this pass and nothing
                // more: the audio is still held, and the next pass — or the
                // final one — decodes it again.
                Logger.transcription.error("Live re-decode failed: \(error)")
            }
        }
    }

    /// Decodes the audio after the settled point. Everything before it is
    /// already spoken for, and clipping there is what keeps a later decode from
    /// rewriting text a person has already read.
    private func decodeFromSettledPoint() async throws -> [DecodedSegment] {
        guard let whisper else { throw TranscriptionError.providerUnavailable }
        let audioSamples = samples
        let settledThrough = redecoding.settledThroughSeconds
        guard Float(audioSamples.count) / Float(WhisperKit.sampleRate) - settledThrough >= Self.leastDecodableSeconds
        else { return [] }

        var options = WhisperProvider.decodingOptions(
            for: settings,
            spellingHints: spellingHints,
            tokenizedBy: whisper.tokenizer
        )
        options.clipTimestamps = [settledThrough]
        let results = try await whisper.transcribe(audioArray: audioSamples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            DecodedSegment(text: $0.text, endSeconds: $0.end)
        }
    }

    // MARK: - Constants

    /// How much new audio earns another decode. A second is what WhisperKit's
    /// own streaming reference waits for, and it is about as long as a person
    /// tolerates between a word being said and appearing.
    nonisolated private static let secondsPerDecode: Float = 1
    nonisolated private static let samplesPerDecode = Int(secondsPerDecode) * WhisperKit.sampleRate
    /// Below this, there is not enough audio past the settled point to decode
    /// into anything but a hallucination.
    nonisolated private static let leastDecodableSeconds: Float = 1
    nonisolated private static let pollInterval: Duration = .milliseconds(100)
}
