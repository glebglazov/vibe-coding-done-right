import Foundation
@testable import vcdr_mac

/// A Library over two mock providers, each with its own directory under a temp
/// root — the same shape the real Library has, with the download replaced by a
/// test writing the files.
@MainActor
struct LibraryEnvironment {
    let root = FileManager.default.temporaryDirectory.appending(path: "vcdr-library-\(UUID().uuidString)")
    /// This Mac's own defaults, one suite per test: both what the app has been
    /// configured with and what the Library remembers about installability.
    let defaults = UserDefaults(suiteName: "vcdr.test.\(UUID().uuidString)")!
    let settings: AppSettings
    let parakeet: MockTranscriptionProvider
    let whisper: MockTranscriptionProvider
    let library: TranscriptionLibrary

    /// One queue for both providers, the way the registry gives one to every
    /// provider it hands out — so a test sees the sequencing the app has.
    let preparationQueue = ModelPreparationQueue()

    /// Builds the Library the way the app builds it, so a test can ask for a
    /// second one over the same Mac.
    private let makeLibrary: @MainActor () -> TranscriptionLibrary

    init() {
        let defaults = defaults
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        self.settings = settings
        parakeet = MockTranscriptionProvider(
            model: .parakeetV3,
            isReady: false,
            preparationPhase: .preparing,
            installedDirectory: root.appending(path: "parakeet"),
            holdsPreparationOpen: true,
            preparationQueue: preparationQueue
        )
        whisper = MockTranscriptionProvider(
            model: .whisperLargeV3Turbo,
            isReady: false,
            preparationPhase: .preparing,
            installedDirectory: root.appending(path: "whisper"),
            holdsPreparationOpen: true,
            preparationQueue: preparationQueue
        )
        let providers = [parakeet, whisper]
        let make: @MainActor () -> TranscriptionLibrary = {
            TranscriptionLibrary(
                models: [.parakeetV3, .whisperLargeV3Turbo],
                provider: { model in providers.first { $0.model == model }! },
                settings: settings,
                installability: ModelInstallabilityCache(defaults: defaults)
            )
        }
        makeLibrary = make
        library = make()
    }

    /// The same Mac on a later launch: a new Library over the same providers and
    /// the same defaults, holding nothing of what the first one read.
    func relaunched() -> TranscriptionLibrary {
        makeLibrary()
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
