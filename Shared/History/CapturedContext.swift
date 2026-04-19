import Foundation

/// Origin of a captured context payload. Unknown raw values round-trip
/// verbatim so older readers don't clobber data written by newer writers.
enum CaptureSource: Codable, Equatable, Sendable {
    /// AX accessibility grab from the frontmost app's selected text
    case selection
    /// Mid-recording or mid-session Cmd+C clipboard capture
    case clipboard
    /// Unknown source from a future schema version; preserves the raw value.
    case unknown(String)

    var rawValue: String {
        switch self {
        case .selection: return "selection"
        case .clipboard: return "clipboard"
        case .unknown(let raw): return raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "selection": self = .selection
        case "clipboard": self = .clipboard
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = CaptureSource(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CapturedContext: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let source: CaptureSource

    init(text: String, source: CaptureSource) {
        self.id = UUID()
        self.text = text
        self.source = source
    }
}
