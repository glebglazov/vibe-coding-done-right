import Foundation

/// Test-only hooks for `ParakeetProvider` initialization. Production code reads
/// these only when set; unit tests configure them via `@testable import`.
enum ParakeetProviderTestSupport {
    /// Invoked at the start of each model load (including test bypass).
    static var onModelLoadStarted: (@Sendable (String) async -> Void)?

    /// When true, `timedLoadModel` records the load and returns a stub timing
    /// without calling `MLModel(contentsOf:)`. `finishWithEncoder` skips
    /// `AsrManager` construction so init-lock tests stay hermetic.
    static var bypassRealMLLoad = false

    /// Artificial delay inside `loadCoreModels` (after download) for reentrancy tests.
    static var simulateCoreLoadDuration: Duration = .zero

    /// Artificial delay at the start of `finishWithEncoder` for coordinator
    /// prewarm / record-during-grind tests.
    static var simulateEncoderLoadDuration: Duration = .zero

    /// Invoked when `finishWithEncoder` begins (after the core phase barrier).
    static var onFinishWithEncoderEntered: (@Sendable () async -> Void)?

    /// Number of times `timedLoadModel` ran (incremented even when bypassing).
    static var modelLoadInvocationCount = 0

    /// Observed `initPhase` values when `recordInitPhases` is true.
    static var recordedInitPhases: [ParakeetProvider.InitPhase] = []

    /// When true, each `initPhase` write is appended to `recordedInitPhases`.
    static var recordInitPhases = false

    static func reset() {
        onModelLoadStarted = nil
        bypassRealMLLoad = false
        simulateCoreLoadDuration = .zero
        simulateEncoderLoadDuration = .zero
        onFinishWithEncoderEntered = nil
        modelLoadInvocationCount = 0
        recordedInitPhases = []
        recordInitPhases = false
    }
}
