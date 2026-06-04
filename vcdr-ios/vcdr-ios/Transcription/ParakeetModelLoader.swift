@preconcurrency import CoreML
import Foundation
import FluidAudio
import OSLog

/// Core models loaded by `ParakeetProvider.loadCoreModels()`; consumed by `finishWithEncoder()`.
struct ParakeetLoadedCoreModels {
    let preprocessor: MLModel?
    let decoder: MLModel?
    let joint: MLModel?
    let vocabulary: [Int: String]
    let repoDirectory: URL
    let preprocessorMs: Double
    let decoderMs: Double
    let jointMs: Double
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
            for name in ["Preprocessor", "Decoder", "JointDecision"] {
                ParakeetProviderTestSupport.modelLoadInvocationCount += 1
                if let hook = ParakeetProviderTestSupport.onModelLoadStarted {
                    await hook(name)
                }
            }
            return ParakeetLoadedCoreModels(
                preprocessor: nil,
                decoder: nil,
                joint: nil,
                vocabulary: [:],
                repoDirectory: repoDirectory,
                preprocessorMs: 1,
                decoderMs: 1,
                jointMs: 1,
                isTestStub: true
            )
        }

        let preprocessorURL = repoDirectory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
        let decoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.decoderFile)
        let jointURL = repoDirectory.appendingPathComponent(ModelNames.ASR.jointFile)
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
        let vocabulary = try await loadVocabulary(from: vocabularyURL)

        return ParakeetLoadedCoreModels(
            preprocessor: preprocessorResult.model,
            decoder: decoderResult.model,
            joint: jointResult.model,
            vocabulary: vocabulary,
            repoDirectory: repoDirectory,
            preprocessorMs: preprocessorResult.milliseconds,
            decoderMs: decoderResult.milliseconds,
            jointMs: jointResult.milliseconds,
            isTestStub: false
        )
    }

    static func loadEncoder(
        from repoDirectory: URL,
        qos: DispatchQoS.QoSClass
    ) async throws -> (model: MLModel?, milliseconds: Double) {
        if ParakeetProviderTestSupport.bypassRealMLLoad {
            ParakeetProviderTestSupport.modelLoadInvocationCount += 1
            if let hook = ParakeetProviderTestSupport.onModelLoadStarted {
                await hook("Encoder")
            }
            return (nil, 1)
        }
        let encoderURL = repoDirectory.appendingPathComponent(ModelNames.ASR.encoderFile)
        let result = try await timedLoadModel(
            name: "Encoder", url: encoderURL, computeUnits: .cpuAndNeuralEngine, qos: qos
        )
        return (result.model, result.milliseconds)
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

    private static func loadVocabulary(from url: URL) async throws -> [Int: String] {
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
