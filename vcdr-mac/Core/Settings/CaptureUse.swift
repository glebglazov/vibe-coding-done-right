import Foundation

enum CaptureUse: String, Codable, CaseIterable {
    case ignored
    case sentAsInput
    case appendedToOutput

    var displayName: String {
        switch self {
        case .ignored: "Not used"
        case .sentAsInput: "Sent as input"
        case .appendedToOutput: "Appended to output"
        }
    }
}

enum CapturePolicy {
    case fixed(CaptureUse)
    case editable(default: CaptureUse)

    var initialUse: CaptureUse {
        switch self {
        case .fixed(let use), .editable(default: let use): use
        }
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    func captureUse(choosing chosen: CaptureUse) -> CaptureUse {
        switch self {
        case .fixed(let use): use
        case .editable: chosen
        }
    }
}
