import Foundation

/// The iOS reading of a Recorded Output Choice: its ids are an AI Prompt Mode
/// and a Text Style.
extension RecordedOutputChoice {
    init(mode: AIPromptMode, style: TextStyle) {
        self.init(
            platform: .ios,
            modeID: mode.rawValue,
            styleID: style.rawValue,
            displayLabel: TranscriptProcessor.outputChoiceLabel(mode: mode, style: style)
        )
    }

    /// Nil for a choice the Mac recorded, and for an id this build does not
    /// know: the caller then uses the current iOS mode.
    var iosMode: AIPromptMode? {
        guard platform == .ios else { return nil }
        return AIPromptMode(rawValue: modeID)
    }

    var iosStyle: TextStyle? {
        guard platform == .ios else { return nil }
        return styleID.flatMap(TextStyle.init(rawValue:))
    }
}
