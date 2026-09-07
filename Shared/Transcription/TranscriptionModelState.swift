import Foundation

/// What one Transcription Model is doing on this device, as the Library shows
/// it. One vocabulary for both products, the way the Model Preparation Phase
/// is. Wider than that phase: the Library is the surface that answers whether a
/// model is here at all and how far along a download is, where the menu bar and
/// the recording pill collapse the whole wait into one label.
enum TranscriptionModelState: Equatable {
    /// Whether this device can install the model is a per-device answer that
    /// needs the network, and it has not arrived. Its own state, so a row can
    /// say so instead of claiming the model is unavailable.
    case installabilityUnknown
    /// The backend publishes no build this device can run.
    case unsupported
    case notInstalled
    case downloading(DownloadProgress)
    /// Another model is preparing and this one is kept back until it finishes,
    /// worded by this model's own narrator so the wait is seen to be moving.
    /// Its own state: a row saying "Installed", or saying nothing new for a
    /// minute, reads as a model that has stopped rather than one in a queue.
    case waitingItsTurn(label: String)
    /// The files are here, and nothing has loaded them this run.
    case installed(bytes: Int64)
    /// The files are here and CoreML is compiling and loading them, worded by
    /// this model's own narrator — the label carries the Preparation Heartbeat,
    /// because a cold load takes minutes and a constant line reads as a hang.
    case loading(label: String)
    /// Loaded, and able to transcribe now.
    case ready(bytes: Int64)
    case failed(PreparationFailure)

    /// The line a Library row shows for this state, size on disk included
    /// whenever there is a cost to weigh — a person deciding what to install,
    /// or what to remove, is deciding by that number.
    ///
    /// Takes the model because an absent one has no files to measure: what its
    /// row can say is what the model declares it will cost, and the states that
    /// say nothing else about cost — a model this device cannot run, a model
    /// whose installability has not come back — say that instead of nothing.
    func label(for model: TranscriptionModel) -> String {
        switch self {
        case .installabilityUnknown:
            "Cannot tell yet what this device can install — needs a connection · \(Self.approximate(model))"
        case .unsupported:
            "This device cannot run this model · \(Self.approximate(model))"
        case .notInstalled:
            "Not installed · \(Self.approximate(model))"
        case .downloading(let progress):
            progress.label
        case .waitingItsTurn(let label):
            label
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
        case .downloading, .loading, .waitingItsTurn: true
        default: false
        }
    }

    /// Whether the model's files are not on this device. These are the states
    /// the Model Installability answer decides between, so an absent model is
    /// the one the Library has a reason to ask the backend about again.
    var isAbsent: Bool {
        switch self {
        case .installabilityUnknown, .unsupported, .notInstalled: true
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

    /// Whether the model's files are on this device. This is what decides
    /// whether a model select may offer it: a select spends nothing, so it
    /// names only models that are already here (`docs/adr/0023`).
    var isOnDisk: Bool {
        switch self {
        case .installed, .ready: true
        default: false
        }
    }

    /// Whether there are files to remove. A download or a load in flight is not
    /// offered for removal: the run holding those files is still using them.
    var offersRemoval: Bool { isOnDisk }

    private static func formatted(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// A declared size, marked as the estimate it is and formatted the way a
    /// measured one is, so the two read as the same kind of number.
    private static func approximate(_ model: TranscriptionModel) -> String {
        "≈ \(formatted(model.approximateSizeOnDisk))"
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

/// Why the Library will not remove a Transcription Model: it is the Default
/// Transcription Model, and that refusal is what guarantees a model select
/// always has something to offer (`docs/adr/0023`).
///
/// The message names the way past itself. Since a select can no longer install,
/// this refusal is the only thing standing between a person and the disk space
/// a model holds, and a refusal that only states the wall leaves them with
/// nowhere to go.
enum ModelRemovalRefusal: Equatable {
    case isDefaultModel

    var message: String {
        switch self {
        case .isDefaultModel:
            "The Default Model is always installed. Install another model, make that one the Default, "
                + "and then this one can go."
        }
    }
}

/// What removing a Transcription Model that Modes pin will cost: each of those
/// Modes loses its pin and follows the Default Transcription Model from then on,
/// moving with it if the Default later changes (`docs/adr/0024`). A pinned model
/// is not refused, it is disclosed and waited on — so this carries both ends of
/// the change a person is being asked to agree to.
struct PinnedModelRemoval: Equatable {
    let model: TranscriptionModel
    /// The Modes whose Transcription Override pins the model, by name — a
    /// disclosure that does not say which Modes leaves the user guessing at what
    /// they are agreeing to.
    let pinningModes: [String]
    let defaultModel: TranscriptionModel

    /// "Email and Notes pin Whisper Large V3 Turbo. Remove it and they will use
    /// Parakeet (the Default Model)."
    var disclosure: String {
        "\(pinningModes.formatted(.list(type: .and))) pin \(model.displayName). "
            + "Remove it and they will use \(defaultModel.displayName) (the Default Model)."
    }
}
