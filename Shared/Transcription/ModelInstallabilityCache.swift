import Foundation

/// What this device has learned about Model Installability: whether the
/// transcription backend publishes a build of a model this device can run. Only
/// the backend can answer that, and only over the network, so the answer is
/// kept between launches — a Library row is then drawn with its Install button
/// already on it, instead of opening as "cannot tell yet" and rewriting itself
/// when a network answer lands.
///
/// Only a definite yes or no is kept. A launch that could not reach the backend
/// leaves nothing behind, so the model stays not known yet — the one case the
/// row's own wording is honest about.
struct ModelInstallabilityCache {

    /// The one key every answer lives under, in this device's own defaults.
    /// Never the App Group's: what a device can run is that device's own fact,
    /// and a phone's answer says nothing about the Mac beside it.
    static let storageKey = "transcription_model_installability"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        answers = defaults.dictionary(forKey: Self.storageKey) as? [String: Bool] ?? [:]
    }

    /// What is known about `model`, or nil while nothing is.
    subscript(model: TranscriptionModel) -> Bool? {
        answers[model.rawValue]
    }

    /// Keeps what the backend answered about `model` — for this launch, and for
    /// every launch after it.
    mutating func remember(_ isInstallable: Bool, of model: TranscriptionModel) {
        answers[model.rawValue] = isInstallable
        defaults.set(answers, forKey: Self.storageKey)
    }

    /// Keyed by the model's raw value rather than by the model, so an answer
    /// belonging to a model this build does not know is carried through a
    /// downgrade instead of taking every other answer down with it.
    private var answers: [String: Bool]
    private let defaults: UserDefaults
}
