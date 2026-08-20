import Foundation

/// Shared JSON coder configuration for history persistence. Used by both
/// `FileHistoryStore` (for snapshot/tombstone I/O) and `UbiquityHistoryStore`
/// (for conflict resolution decodes of `NSFileVersion` siblings).
///
/// The decoder is deliberately tolerant of legacy date formats because
/// pre-migration files on disk were written with the default
/// `JSONEncoder` strategy (TimeInterval doubles), and never normalized.
nonisolated enum HistoryJSONCoders {

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            if let str = try? container.decode(String.self) {
                if let date = isoFractional.date(from: str) { return date }
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: str) { return date }
            }
            if let interval = try? container.decode(TimeInterval.self) {
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format"
            )
        }
        return decoder
    }
}
