import Foundation

/// Shared JSON coder configuration for Substitution persistence. Used by
/// `SubstitutionDatabase` (stored payloads), `SubstitutionFileArchive`
/// (record-file I/O) and `SubstitutionConflictResolver` (decoding
/// `NSFileVersion` siblings).
///
/// Dates round-trip as ISO 8601 **with fractional seconds**: delete-vs-edit and
/// LWW precedence compare `deletedAt`/`lastUpdated` directly, so whole-second
/// truncation would collapse an edit and a same-second delete into a tie. The
/// decoder also accepts the plain (non-fractional) variant so a file written by
/// any peer version still decodes here.
enum SubstitutionJSONCoders {

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
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
            let str = try container.decode(String.self)
            if let date = isoFractional.date(from: str) { return date }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(str)"
            )
        }
        return decoder
    }
}
