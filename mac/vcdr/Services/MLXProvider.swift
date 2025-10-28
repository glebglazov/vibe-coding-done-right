import Foundation
import MLX
import MLXLLM
import MLXRandom

/// LLM provider using Apple's MLX framework for on-device inference
/// Optimized for M-series chips, runs models directly in-process (no server)
///
/// Models must be in MLX format from: https://huggingface.co/mlx-community
/// Download and place in ~/Documents/mlx-models/
class MLXProvider: LLMProvider {
    let id = UUID()
    let name: String
    let requiresAPIKey = false

    /// Path to the model directory
    private let modelPath: String

    /// Loaded model container
    private var modelContainer: ModelContainer?

    /// Generation parameters
    private let temperature: Float
    private let topP: Float
    private let maxTokens: Int

    init(
        modelPath: String,
        modelName: String = "MLX",
        temperature: Float = 0.7,
        topP: Float = 0.9,
        maxTokens: Int = 512
    ) {
        self.modelPath = modelPath
        self.name = "\(modelName) (MLX)"
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    var isAvailable: Bool {
        get async {
            // Check if model directory exists
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: modelPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                print("⚠️ MLX model not found at: \(modelPath)")
                return false
            }

            // Check for required files (config.json, weights, tokenizer)
            let requiredFiles = ["config.json"]
            for file in requiredFiles {
                let filePath = (modelPath as NSString).appendingPathComponent(file)
                guard fileManager.fileExists(atPath: filePath) else {
                    print("⚠️ MLX model missing required file: \(file)")
                    return false
                }
            }

            return true
        }
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        // Log what we're sending to the AI
        print("🤖 ==================== MLX Request ====================")
        print("📦 Model: \(modelPath)")
        if let systemPrompt = systemPrompt {
            print("📋 System Prompt:")
            print(systemPrompt)
            print("---")
        }
        print("💬 User Prompt:")
        print(prompt)
        print("========================================================")

        // Check availability
        guard await isAvailable else {
            throw MLXError.modelNotFound(modelPath)
        }

        // Load model if not already loaded
        if modelContainer == nil {
            print("📥 Loading MLX model from: \(modelPath)")
            do {
                modelContainer = try await ModelContainer.loadModelContainer(modelPath: modelPath)
                print("✅ MLX model loaded successfully")
            } catch {
                print("❌ Failed to load MLX model: \(error)")
                throw MLXError.loadFailed(error.localizedDescription)
            }
        }

        guard let container = modelContainer else {
            throw MLXError.loadFailed("Model container is nil")
        }

        // Build the full prompt with system prompt if provided
        let fullPrompt: String
        if let systemPrompt = systemPrompt {
            // Use a common chat template format
            fullPrompt = """
            <|system|>
            \(systemPrompt)
            <|user|>
            \(prompt)
            <|assistant|>
            """
        } else {
            fullPrompt = prompt
        }

        // Generate response
        var generatedText = ""

        do {
            // Create generation parameters
            let generateParameters = GenerateParameters(
                temperature: temperature,
                topP: topP
            )

            // Generate text (streaming into a string)
            let result = try await container.perform { [fullPrompt, maxTokens, generateParameters] in
                let promptTokens = try await container.tokenizer.encode(text: fullPrompt)

                // Generate tokens
                var outputTokens: [Int] = []
                for try await token in container.generate(
                    promptTokens: MLXArray(promptTokens),
                    parameters: generateParameters,
                    maxTokens: maxTokens
                ) {
                    outputTokens.append(token)
                }

                // Decode tokens to text
                let text = container.tokenizer.decode(tokens: outputTokens)
                return text
            }

            generatedText = result

        } catch {
            print("❌ MLX generation error: \(error)")
            throw MLXError.generationFailed(error.localizedDescription)
        }

        // Log the response
        print("🤖 ==================== MLX Response ====================")
        print(generatedText)
        print("=========================================================")

        return generatedText
    }

    /// Unload the model to free memory
    func unloadModel() {
        modelContainer = nil
        print("🗑️ MLX model unloaded")
    }
}

/// Errors specific to MLX provider
enum MLXError: LocalizedError {
    case modelNotFound(String)
    case loadFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return """
            MLX model not found at: \(path)

            Download models from: https://huggingface.co/mlx-community

            Recommended models:
            - mlx-community/Llama-3.2-3B-Instruct-4bit
            - mlx-community/Qwen2.5-7B-Instruct-4bit
            - mlx-community/gemma-2-9b-it-4bit

            Clone to: ~/Documents/mlx-models/model-name/
            """
        case .loadFailed(let reason):
            return "Failed to load MLX model: \(reason)"
        case .generationFailed(let reason):
            return "MLX generation failed: \(reason)"
        }
    }
}

/// Helper extension for MLX generation parameters
struct GenerateParameters {
    let temperature: Float
    let topP: Float
}
