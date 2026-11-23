@preconcurrency import CoreML
import Foundation
import FluidAudio
import OSLog

/// Core models loaded by `ParakeetProvider.loadCoreModels()`; consumed by `finishWithEncoder()`.
struct ParakeetLoadedCoreModels {
    let preprocessor: MLModel?
    let decoder: MLModel?
    let joint: MLModel?
    let encoderLoadedDuringCorePhase: MLModel?
    let vocabulary: [Int: String]
    let repoDirectory: URL
    let preprocessorMs: Double
    let decoderMs: Double
    let jointMs: Double
    let encoderLoadedDuringCorePhaseMs: Double?
    let isTestStub: Bool
}

/// Per-model `MLModel(contentsOf:)` load durations for warm vs. cold launch classification.
struct ParakeetModelLoadTimings: Sendable {
    let preprocessorMs: Double
    let encoderMs: Double
    let decoderMs: Double
    let jointMs: Double
    var maxAneMs: Double { max(encoderMs, max(decoderMs, jointMs)) }
}

enum ParakeetModelLoader {
    private static let millisecondsPerSecond: Double = 1000
    private static let attosecondsPerMillisecond: Double = 1e15

    /// Loads preprocessor → decoder → joint and vocabulary serially. The encoder
    /// is deliberately excluded and loaded alone in `loadEncoder(from:qos:)`.
    static func loadCoreModelsSerial(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> ParakeetLoadedCoreModels {
        if ParakeetProviderTestSupport.bypassRealMLLoad {
            let preprocessorMs = await loadStubModel(name: "Preprocessor")
            let decoderMs = await loadStubModel(name: "Decoder")
            let jointMs = await loadStubModel(name: "JointDecision")
            return ParakeetLoadedCoreModels(
                preprocessor: nil,
                decoder: nil,
                joint: nil,
                encoderLoadedDuringCorePhase: nil,
                vocabulary: [:],
                repoDirectory: repoDirectory,
                preprocessorMs: preprocessorMs,
                decoderMs: decoderMs,
                jointMs: jointMs,
                encoderLoadedDuringCorePhaseMs: nil,
                isTestStub: true
            )
        }

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointV3File)
        let vocabularyURL = repoDirectory.appendingPathComponent(ModelNames.ASR.vocabularyFile)

        let preprocessorResult = try await timedLoadModel(
            name: "Preprocessor", url: preprocessorURL, computeUnits: .cpuOnly, qos: qos
        )
        let decoderResult = try await timedLoadModel(
            name: "Decoder", url: decoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        let jointResult = try await timedLoadModel(
            name: "JointDecision", url: jointURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        let vocabulary = try await loadVocabulary(from: vocabularyURL, qos: qos)

        return ParakeetLoadedCoreModels(
            preprocessor: preprocessorResult.model,
            decoder: decoderResult.model,
            joint: jointResult.model,
            encoderLoadedDuringCorePhase: nil,
            vocabulary: vocabulary,
            repoDirectory: repoDirectory,
            preprocessorMs: preprocessorResult.milliseconds,
            decoderMs: decoderResult.milliseconds,
            jointMs: jointResult.milliseconds,
            encoderLoadedDuringCorePhaseMs: nil,
            isTestStub: false
        )
    }

    /// Predicted-Warm path: all four model loads are independent cache hits, so
    /// fan them out on GCD and let READY wait on the slowest single load. The
    /// provider still exposes the same two-phase API; `finishWithEncoder()`
    /// consumes the encoder loaded here after the coordinator's prewarm barrier.
    static func loadAllModelsParallelForPredictedWarm(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> ParakeetLoadedCoreModels {
        if ParakeetProviderTestSupport.bypassRealMLLoad {
            async let preprocessorMs = loadStubModel(name: "Preprocessor")
            async let decoderMs = loadStubModel(name: "Decoder")
            async let jointMs = loadStubModel(name: "JointDecision")
            async let encoderMs = loadStubModel(name: "Encoder")
            let timings = await (preprocessorMs, decoderMs, jointMs, encoderMs)
            return ParakeetLoadedCoreModels(
                preprocessor: nil,
                decoder: nil,
                joint: nil,
                encoderLoadedDuringCorePhase: nil,
                vocabulary: [:],
                repoDirectory: repoDirectory,
                preprocessorMs: timings.0,
                decoderMs: timings.1,
                jointMs: timings.2,
                encoderLoadedDuringCorePhaseMs: timings.3,
                isTestStub: true
            )
        }

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointV3File)
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let vocabularyURL = repoDirectory.appendingPathComponent(ModelNames.ASR.vocabularyFile)

        async let preprocessorResult = timedLoadModel(
            name: "Preprocessor", url: preprocessorURL, computeUnits: .cpuOnly, qos: qos
        )
        async let decoderResult = timedLoadModel(
            name: "Decoder", url: decoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let jointResult = timedLoadModel(
            name: "JointDecision", url: jointURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let encoderResult = timedLoadModel(
            name: "Encoder", url: encoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let vocabulary = loadVocabulary(from: vocabularyURL, qos: qos)

        let loaded = try await (
            preprocessorResult,
            decoderResult,
            jointResult,
            encoderResult,
            vocabulary
        )
        return ParakeetLoadedCoreModels(
            preprocessor: loaded.0.model,
            decoder: loaded.1.model,
            joint: loaded.2.model,
            encoderLoadedDuringCorePhase: loaded.3.model,
            vocabulary: loaded.4,
            repoDirectory: repoDirectory,
            preprocessorMs: loaded.0.milliseconds,
            decoderMs: loaded.1.milliseconds,
            jointMs: loaded.2.milliseconds,
            encoderLoadedDuringCorePhaseMs: loaded.3.milliseconds,
            isTestStub: false
        )
    }

    static func loadEncoder(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> (model: MLModel?, milliseconds: Double) {
        if ParakeetProviderTestSupport.bypassRealMLLoad {
            return (nil, await loadStubModel(name: "Encoder"))
        }
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let result = try await timedLoadModel(
            name: "Encoder", url: encoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        return (result.model, result.milliseconds)
    }

    /// Background cache warm path: touch every CoreML artifact with ANE enabled
    /// so iOS pays any E5RT specialization cost outside an interactive launch.
    static func preSpecializeAllModels(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> ParakeetModelLoadTimings {
        if ParakeetProviderTestSupport.bypassRealMLLoad {
            async let preprocessorMs = loadStubModel(name: "Preprocessor")
            async let encoderMs = loadStubModel(name: "Encoder")
            async let decoderMs = loadStubModel(name: "Decoder")
            async let jointMs = loadStubModel(name: "JointDecision")
            let timings = await (preprocessorMs, encoderMs, decoderMs, jointMs)
            return ParakeetModelLoadTimings(
                preprocessorMs: timings.0,
                encoderMs: timings.1,
                decoderMs: timings.2,
                jointMs: timings.3
            )
        }

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointV3File)

        async let preprocessorResult = timedLoadModel(
            name: "Preprocessor", url: preprocessorURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let encoderResult = timedLoadModel(
            name: "Encoder", url: encoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let decoderResult = timedLoadModel(
            name: "Decoder", url: decoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        async let jointResult = timedLoadModel(
            name: "JointDecision", url: jointURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )

        let loaded = try await (preprocessorResult, encoderResult, decoderResult, jointResult)
        return ParakeetModelLoadTimings(
            preprocessorMs: loaded.0.milliseconds,
            encoderMs: loaded.1.milliseconds,
            decoderMs: loaded.2.milliseconds,
            jointMs: loaded.3.milliseconds
        )
    }

    private static func loadStubModel(name: String) async -> Double {
        ParakeetProviderTestSupport.modelLoadInvocationCount += 1
        if let hook = ParakeetProviderTestSupport.onModelLoadStarted {
            await hook(name)
        }
        if ParakeetProviderTestSupport.simulatePerModelLoadDuration > .zero {
            try? await Task.sleep(for: ParakeetProviderTestSupport.simulatePerModelLoadDuration)
        }
        return ParakeetProviderTestSupport.stubModelLoadMilliseconds[name] ?? 1
    }

    private static func timedLoadModel(
        name: String,
        url: URL,
        computeUnits: MLComputeUnits,
        qos: DispatchQoS.QoSClass
    ) async throws -> (model: MLModel, milliseconds: Double) {
        ParakeetProviderTestSupport.modelLoadInvocationCount += 1
        if let hook = ParakeetProviderTestSupport.onModelLoadStarted {
            await hook(name)
        }

        let start = ContinuousClock.now
        let model = try await withThrowingBlockingTask(qos: qos) {
            let configuration = MLModelConfiguration()
            configuration.allowLowPrecisionAccumulationOnGPU = true
            configuration.computeUnits = computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * millisecondsPerSecond
            + Double(duration.components.attoseconds) / attosecondsPerMillisecond
        Logger.transcription.info("[InitTiming] loaded \(name) in \(String(format: "%.0f", ms))ms")
        return (model, ms)
    }

    private static func loadVocabulary(
        from url: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> [Int: String] {
        // Blocking file read + parse stays off the cooperative pool (ADR-0003),
        // same as the model loads beside it.
        try await withThrowingBlockingTask(qos: qos) {
            let data = try Data(contentsOf: url)
            guard let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            var vocabulary: [Int: String] = [:]
            for (key, value) in jsonDict {
                if let tokenId = Int(key) {
                    vocabulary[tokenId] = value
                }
            }
            return vocabulary
        }
    }
}
