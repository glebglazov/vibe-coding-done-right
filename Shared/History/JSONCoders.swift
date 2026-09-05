import Foundation

/// Shared JSON coder configuration for history persistence. Used wherever a
/// record file is read or written — the Local Store's merge and export, and
/// `HistoryConflictResolver`'s decode of `NSFileVersion` siblings.
///
/// The decoder is deliberately tolerant of legacy date formats because files
/// already on disk carry three of them: the default `JSONEncoder` strategy
/// (TimeInterval doubles) from before the migration, whole-second ISO 8601,
/// and the fractional ISO 8601 written now. None is ever normalized.
nonisolated enum HistoryJSONCoders {

    /// Dates are written with fractional seconds. `lastUpdated` is the clock a
    /// merge resolves two copies of a record against, and the second write to
    /// one conversation — the AI output landing on the dictation that produced
    /// it — routinely falls inside the same second as the first. At whole
    /// seconds the later copy is indistinguishable from the earlier one and
    /// never reaches the other device.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
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
