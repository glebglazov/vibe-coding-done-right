import Foundation

extension TranscriptionSettings {

    /// What `mode` transcribes with: its Transcription Override's model under
    /// the Mode's own patch, or the Default Transcription Model and the
    /// Default's family's own settings when the Mode names nothing.
    ///
    /// The whole resolution — Mode's patch, else the family's own settings, else
    /// the family's defaults — is this one function, because a bug in it shows up
    /// as the wrong model being told the wrong thing, with nothing on screen to
    /// say so.
    func effectiveTranscription(for mode: Mode) -> EffectiveTranscription {
        guard let model = mode.transcriptionOverride.model else {
            return EffectiveTranscription(model: defaultModel, settings: modelSettings[defaultModel.family])
        }
        return EffectiveTranscription(
            model: model,
            settings: mode.transcriptionOverride[model.family].applied(to: modelSettings[model.family])
        )
    }
}
