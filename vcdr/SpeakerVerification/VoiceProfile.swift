import Foundation
import OSLog

struct VoiceProfile: Codable, Sendable {
    let mfccMean: [Float]
    let mfccStdDev: [Float]
    let enrollmentDate: Date
    let sampleCount: Int
}

/// Persists a single voice profile to disk.
final class VoiceProfileStore: Sendable {

    // MARK: - Constants

    private static let fileName = "voice_profile.json"

    private let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("vcdr", isDirectory: true))
    {
        self.fileURL = directory.appendingPathComponent(Self.fileName)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> VoiceProfile? {
        guard let data = try? Data(contentsOf: fileURL),
              let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data) else {
            return nil
        }
        return profile
    }

    func save(_ profile: VoiceProfile) {
        do {
            let data = try JSONEncoder().encode(profile)
            try data.write(to: fileURL, options: .atomic)
            Logger.voiceLock.info("Voice profile saved (\(profile.sampleCount) samples)")
        } catch {
            Logger.voiceLock.error("Failed to save voice profile: \(error)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        Logger.voiceLock.info("Voice profile deleted")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}
