import Foundation
import OSLog

/// The Transcription Model Library: which models this device has installed,
/// what each install costs on disk, and the two things a person can do about it
/// — add one, remove one that is not the Default.
@Observable
final class TranscriptionLibrary {

    struct Entry: Identifiable {
        let model: TranscriptionModel
        let state: TranscriptionModelState
        var id: TranscriptionModel { model }
    }

    /// Every model this platform offers, in the order it offers them, each with
    /// its own state. Never shortened: a model whose installability is not
    /// known yet is a row saying so, not a row withheld.
    var entries: [Entry] {
        models.map(entry(for:))
    }

    /// One model's row, for a screen that shows a single model rather than the
    /// whole Library — a Mode's own screen shows the model it names.
    func entry(for model: TranscriptionModel) -> Entry {
        Entry(model: model, state: states[model] ?? .installabilityUnknown)
    }

    private let models: [TranscriptionModel]
    private let provider: (TranscriptionModel) -> any TranscriptionProvider
    private let settings: AppSettings

    private var states: [TranscriptionModel: TranscriptionModelState] = [:]
    /// Whether this Mac can install a model, as far as the backend has
    /// said — this launch or an earlier one. Absent until an answer arrives,
    /// which is what the unknown state renders.
    private var installability: ModelInstallabilityCache
    /// One clock per model, so the Preparation Heartbeat a row shows measures
    /// that model's own wait rather than whichever model asked last.
    @ObservationIgnored private var narrators: [TranscriptionModel: ModelPreparationNarrator] = [:]
    @ObservationIgnored private var installations: [TranscriptionModel: Task<Void, Never>] = [:]

    init(
        models: [TranscriptionModel],
        provider: @escaping (TranscriptionModel) -> any TranscriptionProvider,
        settings: AppSettings,
        installability: ModelInstallabilityCache = ModelInstallabilityCache()
    ) {
        self.models = models
        self.provider = provider
        self.settings = settings
        self.installability = installability
    }

    /// Keeps the Library telling the truth for as long as a screen is showing
    /// it: one read of everything, then every preparing model re-read at the
    /// Preparation Heartbeat's cadence until the screen goes away. The loop
    /// belongs here rather than to `install()` because a preparation this
    /// Library never started — the Default being prepared at launch — is read
    /// off the provider the same way, and has to reach the row too.
    func watch() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.statePollingInterval)
            await refreshPreparingModels()
        }
    }

    /// Reads every model's state, then asks the backends whose model is not
    /// here whether this Mac could run it. Cheap to run at launch and on each
    /// visit to the screen — and either is how an answer that never arrived, on
    /// a device that was offline, gets asked for a second time.
    func refresh() async {
        for model in models {
            await refreshState(of: model)
        }
        // Only a model that is absent needs the network answer: one already on
        // disk is installable by the fact of being installed, and a screen
        // opened with everything installed asks nothing of the network. An
        // absent model is asked even when its answer is remembered, because the
        // backend can publish a build for this Mac between two launches — which
        // is what leaves a remembered answer needing no expiry.
        for model in models where states[model]?.isAbsent == true {
            await askInstallability(of: model)
            await refreshState(of: model)
        }
    }

    /// Installs `model` — the download and the load, which together are what
    /// preparing it means. Also the retry a Preparation Failure offers: the
    /// provider begins a fresh attempt, and a second press while one runs joins
    /// that attempt rather than downloading twice.
    func install(_ model: TranscriptionModel, urgency: PreparationUrgency) {
        guard installations[model] == nil else { return }
        let provider = provider(model)
        installations[model] = Task {
            // Whatever stopped it rides on the phase, which the next state read
            // picks up — the throw has nothing left to tell this screen.
            try? await provider.initialize(urgency: urgency)
            await refreshState(of: model)
            installations[model] = nil
        }
    }

    /// Why removing `model` is refused, or nil when it can go. A model may be
    /// removed whenever nothing names it: not the Default Transcription Model,
    /// and not any Mode's Transcription Override.
    func removalRefusal(for model: TranscriptionModel) -> ModelRemovalRefusal? {
        if model == settings.transcriptionSettings.defaultModel { return .isDefaultModel }
        let namingModes = settings.modes
            .filter { $0.transcriptionOverride.model == model }
            .map(\.name)
        return namingModes.isEmpty ? nil : .namedByModes(namingModes)
    }

    /// The Transcription Override a Mode gets when a model is named on its
    /// screen. The model is installed there and then, so first use is warm
    /// rather than a download that runs while the person is speaking; naming
    /// nothing returns the Mode to the Default and installs nothing.
    func override(_ override: TranscriptionOverride, naming model: TranscriptionModel?) -> TranscriptionOverride {
        if let model { install(model, urgency: .unawaited) }
        var named = override
        named.model = model
        return named
    }

    /// Deletes `model`'s files, or returns why it will not. Settings are
    /// untouched: a removed model keeps everything it was configured with, so
    /// installing it again finds its own answers waiting.
    @discardableResult
    func remove(_ model: TranscriptionModel) async -> ModelRemovalRefusal? {
        if let refusal = removalRefusal(for: model) { return refusal }

        let provider = provider(model)
        do {
            try TranscriptionModelFiles(directory: provider.installedDirectory).remove()
            Logger.transcription.info("Removed \(model.rawValue) from the model root")
        } catch {
            Logger.transcription.error("Could not remove \(model.rawValue): \(error)")
        }
        await refreshState(of: model)
        return nil
    }

    // MARK: - Constants

    /// The same cadence the app's own readiness polls its provider at.
    private static let statePollingInterval: Duration = .milliseconds(200)

    // MARK: - Reading a model's state

    /// Re-reads only the models with something to report: one already moving,
    /// and one whose provider has just started moving. Sizing an install on
    /// disk is what a state read costs, and an idle Library owes nobody that.
    private func refreshPreparingModels() async {
        for model in models {
            let phase = await provider(model).initPhase
            let hasStartedMoving = phase == .downloadingModel || phase == .loadingModel
                || phase == .waitingItsTurn
            guard states[model]?.isPreparing == true || hasStartedMoving else { continue }
            await refreshState(of: model)
        }
    }

    private func refreshState(of model: TranscriptionModel) async {
        let state = await state(of: model)
        if states[model] != state {
            states[model] = state
        }
    }

    private func state(of model: TranscriptionModel) async -> TranscriptionModelState {
        let provider = provider(model)
        let phase = await provider.initPhase

        switch phase {
        case .downloadingModel:
            if let fraction = await provider.downloadProgress {
                return .downloading(.fraction(fraction))
            }
            return .downloading(.elapsed(label: label(for: phase, of: model)))
        case .loadingModel:
            return .loading(label: label(for: phase, of: model))
        case .waitingItsTurn:
            return .waitingItsTurn(label: label(for: phase, of: model))
        case .failed(let failure):
            return .failed(failure)
        case .preparing, .ready:
            // Disk decides before the phase does: a provider loaded this run
            // still reports `.ready` after its files have been removed, and a
            // provider nothing has prepared reports `.preparing` forever.
            guard provider.isInstalled else { return uninstalledState(of: model) }
            // Being installed answers whether this Mac can install it, so a
            // removal later never asks the network for what is already known.
            installability.remember(true, of: model)
            let bytes = TranscriptionModelFiles(directory: provider.installedDirectory).sizeOnDisk ?? 0
            return phase == .ready ? .ready(bytes: bytes) : .installed(bytes: bytes)
        }
    }

    private func uninstalledState(of model: TranscriptionModel) -> TranscriptionModelState {
        switch installability[model] {
        case .some(true): .notInstalled
        case .some(false): .unsupported
        case .none: .installabilityUnknown
        }
    }

    private func askInstallability(of model: TranscriptionModel) async {
        do {
            installability.remember(try await provider(model).isInstallableOnThisDevice(), of: model)
        } catch {
            // Left unknown on purpose: a lost connection means the Library does
            // not know what this Mac can run, which is not the same as knowing
            // it cannot run it.
            Logger.transcription.error("Could not tell whether \(model.rawValue) is installable: \(error)")
        }
    }

    /// This model's phase, worded by this model's own narrator so the heartbeat
    /// counts the wait in front of the person reading the row.
    private func label(for phase: ModelPreparationPhase, of model: TranscriptionModel) -> String {
        var narrator = narrators[model] ?? ModelPreparationNarrator()
        let readiness = narrator.readiness(for: phase)
        narrators[model] = narrator
        if case .preparing(let label) = readiness { return label }
        return phase.label(elapsedSeconds: 0)
    }
}
