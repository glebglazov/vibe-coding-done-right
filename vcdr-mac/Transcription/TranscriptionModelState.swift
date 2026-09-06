import Foundation

/// What one Transcription Model is doing on this device, as the Library shows
/// it. Wider than the Model Preparation Phase: the Library is the surface that
/// answers whether a model is here at all and how far along a download is,
/// where the menu bar and the recording pill collapse the whole wait into one
/// label.
enum TranscriptionModelState: Equatable {
    /// Whether this Mac can install the model is a per-device answer that needs
    /// the network, and it has not arrived. Its own state, so a row can say so
    /// instead of claiming the model is unavailable.
    case installabilityUnknown
    /// The backend publishes no build this Mac can run.
    case unsupported
    case notInstalled
    case downloading(DownloadProgress)
    /// The files are here, and nothing has loaded them this run.
    case installed(bytes: Int64)
    /// The files are here and CoreML is compiling and loading them, worded by
    /// this model's own narrator — the label carries the Preparation Heartbeat,
    /// because a cold load takes minutes and a constant line reads as a hang.
    case loading(label: String)
    /// Loaded, and able to transcribe now.
    case ready(bytes: Int64)
    case failed(PreparationFailure)

    /// The line a Library row shows for this state, size on disk included when
    /// there is an install to weigh — a person deciding what to remove is
    /// deciding by that number.
    var label: String {
        switch self {
        case .installabilityUnknown:
            "Cannot tell yet what this Mac can install — needs a connection"
        case .unsupported:
            "This Mac cannot run this model"
        case .notInstalled:
            "Not installed"
        case .downloading(let progress):
            progress.label
        case .installed(let bytes):
            "Installed · \(Self.formatted(bytes))"
        case .loading(let label):
            label
        case .ready(let bytes):
            "Ready · \(Self.formatted(bytes))"
        case .failed(let failure):
            failure.headline
        }
    }

    /// Whether this is a state that moves on its own, so a screen watching the
    /// Library knows which rows are worth re-reading.
    var isPreparing: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }

    /// What the install button says, or nil when there is nothing to install. A
    /// retry is the same install run again, worded as what it is.
    var installTitle: String? {
        switch self {
        case .notInstalled: "Install"
        case .failed: "Try Again"
        default: nil
        }
    }

    /// Whether there are files to remove. A download or a load in flight is not
    /// offered for removal: the run holding those files is still using them.
    var offersRemoval: Bool {
        switch self {
        case .installed, .ready: true
        default: false
        }
    }

    private static func formatted(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// How far a download has got. WhisperKit reports a fraction of the whole;
/// FluidAudio reports nothing, so Parakeet's honest answer is the Preparation
/// Heartbeat — the time it has spent — which is the same choice the recording
/// pill already made for it.
enum DownloadProgress: Equatable {
    case fraction(Double)
    case elapsed(label: String)

    var label: String {
        switch self {
        case .fraction(let fraction):
            "Downloading · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .elapsed(let label):
            label
        }
    }

    /// The value a progress bar can draw, or nil when the backend gives a
    /// progress bar nothing to draw.
    var fraction: Double? {
        switch self {
        case .fraction(let fraction): fraction
        case .elapsed: nil
        }
    }
}

/// Why the Library will not remove a Transcription Model: something names it.
/// The Default names it, or a Mode's Transcription Override does. Either way the
/// refusal carries the reason rather than repointing what named it at another
/// model on the user's behalf, which would change what those runs transcribe
/// with and therefore what they produce (`docs/adr/0018`).
enum ModelRemovalRefusal: Equatable {
    case isDefaultModel
    /// The Modes whose Transcription Override names this model, by name — a
    /// refusal that does not say which Modes leaves the user hunting for them.
    case namedByModes([String])

    var message: String {
        switch self {
        case .isDefaultModel:
            "The Default Model is always installed. Make another model the Default first, then remove this one."
        case .namedByModes(let names):
            "Named by \(names.formatted(.list(type: .and))). "
                + "Point every one of them at another model first, then remove this one."
        }
    }
}
