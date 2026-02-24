import Foundation
import OSLog

@Observable
final class TranscriptionHistory {
    private(set) var records: [TranscriptionRecord] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Constants
    static let maxRecords = 500

    init(directory: URL = TranscriptionHistory.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("history.json")
        self.records = Self.load(from: fileURL, decoder: decoder)
    }

    func addRecord(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    func removeRecord(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clearAll() {
        records.removeAll()
        save()
    }

    var latestRecord: TranscriptionRecord? {
        records.first
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.app.error("Failed to save transcription history: \(error)")
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> [TranscriptionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([TranscriptionRecord].self, from: data)) ?? []
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VCDR")
    }
}
