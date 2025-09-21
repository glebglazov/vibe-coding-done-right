//
//  WhisperKitService.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import WhisperKit

class WhisperKitService {
    static let shared = WhisperKitService()

    private var whisperKit: WhisperKit?
    private var isInitialized = false

    private init() {}

    func initialize() async throws {
        guard !isInitialized else { return }

        do {
            // Initialize WhisperKit with small model for better speed
            whisperKit = try await WhisperKit(model: "openai_whisper-small")
            isInitialized = true
            print("WhisperKit initialized successfully with small model")
        } catch {
            print("Failed to initialize WhisperKit: \(error)")
            throw WhisperKitError.initializationFailed(error.localizedDescription)
        }
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        guard isInitialized, let whisperKit = whisperKit else {
            throw WhisperKitError.notInitialized
        }

        do {
            // Transcribe the audio file with automatic language detection
            print("🎤 Starting transcription with auto-detect language...")

            // Get task setting from user preferences
            let settings = AppSettings.shared
            let task: DecodingTask = settings.whisperTask == "translate" ? .translate : .transcribe

            print("🎛️ Using Whisper task: \(settings.whisperTask)")

            let transcriptionResults = try await whisperKit.transcribe(
                audioPath: audioFileURL.path,
                decodeOptions: DecodingOptions(
                    task: task,
                    language: nil,
                    detectLanguage: true
                )
            )

            // Extract text from all segments
            guard !transcriptionResults.isEmpty else {
                throw WhisperKitError.emptyResult
            }

            // Get the first result and extract clean text from segments
            let firstResult = transcriptionResults[0]

            // Log detected language information
            let detectedLanguage = firstResult.language
            print("🌍 WhisperKit detected language: \(detectedLanguage)")

            let transcription = firstResult.segments.compactMap { $0.text }.joined(separator: " ")

            // Clean up the text by removing SRLet's check.T formatting and extra whitespace
            let cleanText = cleanTranscriptionText(transcription)

            if cleanText.isEmpty {
                throw WhisperKitError.emptyResult
            }

            print("📝 WhisperKit transcription: \(cleanText)")
            return cleanText

        } catch {
            print("WhisperKit transcription error: \(error)")
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func cleanTranscriptionText(_ text: String) -> String {
        var cleanText = text

        // Remove SRT-style tags like <|startoftranscript|>, <|en|>, etc.
        cleanText = cleanText.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)

        // Remove timestamps like [0.00] or [18.20]
        cleanText = cleanText.replacingOccurrences(of: "\\[\\d+\\.\\d+\\]", with: "", options: .regularExpression)

        // Remove standalone numbers like "> 1, 2, 3..."
        cleanText = cleanText.replacingOccurrences(of: "> \\d+(, \\d+)*\\.\\.\\.", with: "", options: .regularExpression)

        // Remove remaining angle brackets with content
        cleanText = cleanText.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)

        // Clean up multiple spaces and trim
        cleanText = cleanText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleanText
    }
}

enum WhisperKitError: Error {
    case notInitialized
    case initializationFailed(String)
    case emptyResult
    case transcriptionFailed(String)

    var localizedDescription: String {
        switch self {
        case .notInitialized:
            return "WhisperKit not initialized. Call initialize() first."
        case .initializationFailed(let error):
            return "Failed to initialize WhisperKit: \(error)"
        case .emptyResult:
            return "Transcription returned empty result"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error)"
        }
    }
}
