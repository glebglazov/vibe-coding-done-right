//
//  WhisperKitService.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import WhisperKit

class WhisperKitService: TranscriptionProvider {
    static let shared = WhisperKitService()

    // TranscriptionProvider conformance
    let id = UUID()
    let name = "WhisperKit"

    var isAvailable: Bool {
        get async {
            // WhisperKit is always available on macOS with CoreML
            return true
        }
    }

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
            throw TranscriptionError.initializationFailed(error.localizedDescription)
        }
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        guard isInitialized, let whisperKit = whisperKit else {
            throw TranscriptionError.transcriptionFailed("WhisperKit not initialized")
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
                throw TranscriptionError.transcriptionFailed("Empty transcription result")
            }

            // Get the first result and extract clean text from segments
            let firstResult = transcriptionResults[0]

            // Log detected language information
            let detectedLanguage = firstResult.language
            print("🌍 WhisperKit detected language: \(detectedLanguage)")

            let transcription = firstResult.segments.compactMap { $0.text }.joined(separator: " ")
            print("🔍 Raw transcription before cleaning: \"\(transcription)\"")

            // Clean up the text by removing SRT formatting and extra whitespace
            let cleanText = cleanTranscriptionText(transcription)

            // If cleaning resulted in empty text, return a placeholder or raw text
            if cleanText.isEmpty {
                print("⚠️ Clean text is empty, checking segments...")

                // If we have segments with text, return the raw transcription
                if !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("📝 Returning raw transcription: \(transcription)")
                    return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // If even raw transcription is empty but we got segments, log them
                if !firstResult.segments.isEmpty {
                    print("📊 Segments count: \(firstResult.segments.count)")
                    for (index, segment) in firstResult.segments.prefix(3).enumerated() {
                        print("  Segment \(index): \"\(segment.text)\" (prob: \(segment.avgLogprob))")
                    }
                }

                // Return a helpful message instead of throwing
                print("⚠️ Transcription appears to be silence or unclear audio")
                return "[No speech detected]"
            }

            print("📝 WhisperKit transcription: \(cleanText)")
            return cleanText

        } catch {
            print("WhisperKit transcription error: \(error)")
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
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
