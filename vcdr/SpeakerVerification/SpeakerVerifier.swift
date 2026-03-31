import Foundation

enum SpeakerVerificationError: LocalizedError {
    case noVoiceProfile
    case verificationFailed
    case audioReadFailed(String)
    case enrollmentFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVoiceProfile:
            "No voice profile enrolled"
        case .verificationFailed:
            "Voice not recognized"
        case .audioReadFailed(let message):
            "Failed to read audio: \(message)"
        case .enrollmentFailed(let message):
            "Enrollment failed: \(message)"
        }
    }
}

struct VerificationResult: Sendable {
    let isMatch: Bool
    let confidence: Float
}

protocol SpeakerVerifier: Sendable {
    var hasEnrolledProfile: Bool { get async }
    func enroll(audioURLs: [URL]) async throws
    func verify(audioURL: URL) async throws -> VerificationResult
    func deleteProfile() async
}
