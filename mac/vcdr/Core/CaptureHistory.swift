//
//  CaptureHistory.swift
//  vcdr
//
//  Created by Claude Code
//

import Foundation
import Combine

/// Manages capture history storage and retrieval
@MainActor
class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()

    @Published private(set) var entries: [CaptureHistoryEntry] = []

    private let storageURL: URL
    private static let maxEntries = 1000 // Keep last 1000 entries

    private init() {
        // Store in Application Support directory
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let appDirectory = appSupport.appendingPathComponent("com.glazov.vcdr", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )

        storageURL = appDirectory.appendingPathComponent("capture_history.json")

        loadHistory()
    }

    /// Add a new entry to history
    func addEntry(_ entry: CaptureHistoryEntry) {
        entries.insert(entry, at: 0) // Most recent first

        // Trim if exceeding max
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        saveHistory()
        print("📝 Added capture history entry: \(entry.id)")
    }

    /// Load history from disk
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            print("📚 No existing history file found")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([CaptureHistoryEntry].self, from: data)
            print("📚 Loaded \(entries.count) history entries")
        } catch {
            print("❌ Failed to load history: \(error)")
            entries = []
        }
    }

    /// Save history to disk
    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(entries)
            try data.write(to: storageURL, options: .atomic)
            print("💾 Saved \(entries.count) history entries")
        } catch {
            print("❌ Failed to save history: \(error)")
        }
    }

    /// Clear all history
    func clearHistory() {
        entries = []
        saveHistory()
        print("🗑️ Cleared all history")
    }

    /// Delete a specific entry
    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        saveHistory()
        print("🗑️ Deleted history entry: \(id)")
    }
}
