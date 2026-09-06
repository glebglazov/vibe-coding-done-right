import Foundation
@testable import vcdr_mac

/// A Library over two mock providers, each with its own directory under a temp
/// root — the same shape the real Library has, with the download replaced by a
/// test writing the files.
@MainActor
struct LibraryEnvironment {
    let root = FileManager.default.temporaryDirectory.appending(path: "vcdr-library-\(UUID().uuidString)")
    let settings: AppSettings
    let parakeet: MockTranscriptionProvider
    let whisper: MockTranscriptionProvider
    let library: TranscriptionLibrary

    init() {
        settings = AppSettings(
            userDefaults: UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!,
            secretStore: InMemorySecretStore()
        )
        parakeet = MockTranscriptionProvider(
            model: .parakeetV3,
            isReady: false,
            preparationPhase: .preparing,
            installedDirectory: root.appending(path: "parakeet"),
            holdsPreparationOpen: true
        )
        whisper = MockTranscriptionProvider(
            model: .whisperLargeV3Turbo,
            isReady: false,
            preparationPhase: .preparing,
            installedDirectory: root.appending(path: "whisper"),
            holdsPreparationOpen: true
        )
        let providers = [parakeet, whisper]
        library = TranscriptionLibrary(
            models: [.parakeetV3, .whisperLargeV3Turbo],
            provider: { model in providers.first { $0.model == model }! },
            settings: settings
        )
    }

    func installFiles(for provider: MockTranscriptionProvider, bytes: Int) {
        let directory = provider.installedDirectory
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data(repeating: 0, count: bytes).write(to: directory.appending(path: "weights.bin"))
    }

    func state(of model: TranscriptionModel) -> TranscriptionModelState? {
        library.entries.first { $0.model == model }?.state
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
