import Accelerate
import AVFoundation
import OSLog

/// Extracts MFCC (Mel-Frequency Cepstral Coefficient) features from 16kHz mono PCM audio.
/// Used for speaker verification by computing a compact voice signature.
struct AudioFeatureExtractor: Sendable {

    // MARK: - Constants

    /// Number of MFCC coefficients to extract per frame
    static let mfccCount = 13
    /// FFT window size in samples (25ms at 16kHz)
    private static let frameLength = 400
    /// Step between consecutive frames in samples (10ms at 16kHz)
    private static let hopLength = 160
    /// Number of mel filter banks
    private static let melFilterCount = 26
    /// Sample rate expected by this extractor (matches Parakeet's native rate)
    private static let sampleRate: Float = 16000
    /// Minimum frequency for mel filterbank (Hz)
    private static let melMinFreq: Float = 0
    /// Maximum frequency for mel filterbank (Hz) — Nyquist for 16kHz
    private static let melMaxFreq: Float = 8000

    // MARK: - Public API

    /// Extracts mean and standard deviation of MFCC features from an audio file.
    /// Returns a tuple of (mean, stddev) vectors, each with `mfccCount` elements.
    static func extractMFCCSummary(from audioURL: URL) throws -> (mean: [Float], stdDev: [Float]) {
        let samples = try readAudioSamples(from: audioURL)
        let frameMFCCs = computeFrameMFCCs(samples: samples)

        guard !frameMFCCs.isEmpty else {
            throw SpeakerVerificationError.audioReadFailed("Audio too short for feature extraction")
        }

        let frameCount = frameMFCCs.count
        var mean = [Float](repeating: 0, count: mfccCount)
        var stdDev = [Float](repeating: 0, count: mfccCount)

        // Compute mean across all frames for each coefficient
        for coeff in 0..<mfccCount {
            var sum: Float = 0
            for frame in frameMFCCs {
                sum += frame[coeff]
            }
            mean[coeff] = sum / Float(frameCount)
        }

        // Compute standard deviation
        for coeff in 0..<mfccCount {
            var varianceSum: Float = 0
            for frame in frameMFCCs {
                let diff = frame[coeff] - mean[coeff]
                varianceSum += diff * diff
            }
            stdDev[coeff] = sqrt(varianceSum / Float(frameCount))
        }

        return (mean, stdDev)
    }

    // MARK: - Audio I/O

    private static func readAudioSamples(from url: URL) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SpeakerVerificationError.audioReadFailed(error.localizedDescription)
        }

        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SpeakerVerificationError.audioReadFailed("Failed to create audio buffer")
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            throw SpeakerVerificationError.audioReadFailed(error.localizedDescription)
        }

        guard let channelData = buffer.floatChannelData else {
            throw SpeakerVerificationError.audioReadFailed("No float channel data available")
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return samples
    }

    // MARK: - MFCC Computation

    private static func computeFrameMFCCs(samples: [Float]) -> [[Float]] {
        let fftSize = frameLength
        guard samples.count >= fftSize else { return [] }

        let melFilterbank = buildMelFilterbank(fftSize: fftSize)
        let window = hanningWindow(size: fftSize)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            Logger.voiceLock.error("Failed to create FFT setup")
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var allMFCCs: [[Float]] = []
        var frameStart = 0

        while frameStart + fftSize <= samples.count {
            // Extract and window the frame
            var frame = Array(samples[frameStart..<(frameStart + fftSize)])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))

            // Compute power spectrum via FFT
            let powerSpectrum = computePowerSpectrum(frame: frame, fftSetup: fftSetup, log2n: log2n)

            // Apply mel filterbank
            let melEnergies = applyMelFilterbank(powerSpectrum: powerSpectrum, filterbank: melFilterbank)

            // Log compress
            var logMelEnergies = melEnergies.map { max(log($0), -20.0) }

            // DCT to get MFCCs
            let mfccs = dctType2(input: &logMelEnergies, outputCount: mfccCount)
            allMFCCs.append(mfccs)

            frameStart += hopLength
        }

        return allMFCCs
    }

    // MARK: - FFT

    private static func computePowerSpectrum(
        frame: [Float], fftSetup: FFTSetup, log2n: vDSP_Length
    ) -> [Float] {
        let n = frame.count
        let halfN = n / 2

        // Pack real data into split complex format
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        frame.withUnsafeBufferPointer { framePtr in
            framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
            }
        }

        // Forward FFT
        var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Compute magnitude squared (power spectrum)
        var power = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&splitComplex, 1, &power, 1, vDSP_Length(halfN))

        // Scale by 1/N^2 for proper normalization
        var scale = 1.0 / Float(n * n)
        vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(halfN))

        return power
    }

    // MARK: - Mel Filterbank

    private static func hzToMel(_ hz: Float) -> Float {
        1127.0 * log(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (exp(mel / 1127.0) - 1.0)
    }

    private static func buildMelFilterbank(fftSize: Int) -> [[Float]] {
        let numBins = fftSize / 2
        let melMin = hzToMel(melMinFreq)
        let melMax = hzToMel(melMaxFreq)

        // Linearly spaced mel points
        var melPoints = [Float](repeating: 0, count: melFilterCount + 2)
        let melStep = (melMax - melMin) / Float(melFilterCount + 1)
        for i in 0..<(melFilterCount + 2) {
            melPoints[i] = melMin + Float(i) * melStep
        }

        // Convert mel points to FFT bin indices
        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int((hz / sampleRate) * Float(fftSize))
        }

        // Build triangular filters
        var filterbank = [[Float]]()
        for m in 0..<melFilterCount {
            var filter = [Float](repeating: 0, count: numBins)
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in left..<center where k < numBins {
                let denom = Float(center - left)
                if denom > 0 {
                    filter[k] = Float(k - left) / denom
                }
            }
            for k in center..<right where k < numBins {
                let denom = Float(right - center)
                if denom > 0 {
                    filter[k] = Float(right - k) / denom
                }
            }
            filterbank.append(filter)
        }

        return filterbank
    }

    private static func applyMelFilterbank(powerSpectrum: [Float], filterbank: [[Float]]) -> [Float] {
        // Floor to avoid log(0)
        let floorValue: Float = 1e-10
        return filterbank.map { filter in
            var energy: Float = 0
            let count = min(powerSpectrum.count, filter.count)
            vDSP_dotpr(powerSpectrum, 1, filter, 1, &energy, vDSP_Length(count))
            return max(energy, floorValue)
        }
    }

    // MARK: - DCT

    /// Type-II DCT to convert log mel energies to cepstral coefficients.
    private static func dctType2(input: inout [Float], outputCount: Int) -> [Float] {
        let inputCount = input.count
        var output = [Float](repeating: 0, count: outputCount)

        for k in 0..<outputCount {
            var sum: Float = 0
            for n in 0..<inputCount {
                sum += input[n] * cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(inputCount))
            }
            output[k] = sum
        }

        return output
    }

    // MARK: - Window

    private static func hanningWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return window
    }
}
