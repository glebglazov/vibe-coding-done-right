import Foundation
import OSLog

/// Speaker verification using MFCC (Mel-Frequency Cepstral Coefficient) voice embeddings.
/// Compares cosine similarity of MFCC feature vectors to determine if audio
/// matches the enrolled voice profile.
actor MFCCSpeakerVerifier: SpeakerVerifier {

    // MARK: - Constants

    /// Default cosine similarity threshold for a positive match.
    /// Values above this are considered the same speaker.
    static let defaultThreshold: Float = 0.85
    /// Minimum number of enrollment samples for a reliable profile
    static let minimumEnrollmentSamples = 1
    /// Maximum number of enrollment samples to use
    static let maximumEnrollmentSamples = 5

    // MARK: - Properties

    private let store: VoiceProfileStore
    private var thresholdValue: Float
    private var cachedProfile: VoiceProfile?

    init(store: VoiceProfileStore, threshold: Float = defaultThreshold) {
        self.store = store
        self.thresholdValue = threshold
        self.cachedProfile = store.load()
    }

    func updateThreshold(_ value: Float) {
        thresholdValue = value
    }

    var hasEnrolledProfile: Bool {
        cachedProfile != nil
    }

    // MARK: - Enrollment

    func enroll(audioURLs: [URL]) async throws {
        guard audioURLs.count >= Self.minimumEnrollmentSamples else {
            throw SpeakerVerificationError.enrollmentFailed(
                "Need at least \(Self.minimumEnrollmentSamples) audio sample(s)"
            )
        }

        let urls = Array(audioURLs.prefix(Self.maximumEnrollmentSamples))
        var allMeans: [[Float]] = []
        var allStdDevs: [[Float]] = []

        for url in urls {
            let summary = try AudioFeatureExtractor.extractMFCCSummary(from: url)
            allMeans.append(summary.mean)
            allStdDevs.append(summary.stdDev)
        }

        // Average the means and stddevs across all enrollment samples
        let coeffCount = AudioFeatureExtractor.mfccCount
        var combinedMean = [Float](repeating: 0, count: coeffCount)
        var combinedStdDev = [Float](repeating: 0, count: coeffCount)

        for coeff in 0..<coeffCount {
            var meanSum: Float = 0
            var stdSum: Float = 0
            for i in 0..<allMeans.count {
                meanSum += allMeans[i][coeff]
                stdSum += allStdDevs[i][coeff]
            }
            combinedMean[coeff] = meanSum / Float(allMeans.count)
            combinedStdDev[coeff] = stdSum / Float(allStdDevs.count)
        }

        let profile = VoiceProfile(
            mfccMean: combinedMean,
            mfccStdDev: combinedStdDev,
            enrollmentDate: Date(),
            sampleCount: urls.count
        )

        store.save(profile)
        cachedProfile = profile
        Logger.voiceLock.info("Voice profile enrolled with \(urls.count) sample(s)")
    }

    // MARK: - Verification

    func verify(audioURL: URL) async throws -> VerificationResult {
        guard let profile = cachedProfile else {
            throw SpeakerVerificationError.noVoiceProfile
        }

        let summary = try AudioFeatureExtractor.extractMFCCSummary(from: audioURL)
        let similarity = cosineSimilarity(summary.mean, profile.mfccMean)
        let currentThreshold = thresholdValue
        let isMatch = similarity >= currentThreshold

        Logger.voiceLock.info(
            "Speaker verification: similarity=\(String(format: "%.3f", similarity)), threshold=\(String(format: "%.2f", currentThreshold)), match=\(isMatch)"
        )

        return VerificationResult(isMatch: isMatch, confidence: similarity)
    }

    // MARK: - Profile Management

    func deleteProfile() {
        store.delete()
        cachedProfile = nil
        Logger.voiceLock.info("Voice profile deleted")
    }

    // MARK: - Similarity

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }

        return dotProduct / denominator
    }
}
