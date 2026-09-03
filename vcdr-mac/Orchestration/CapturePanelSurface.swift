import AppKit

/// Configuration passed to `CapturePanelSurface.show(config:)`.
/// Groups the previously-inline parameters of `CapturePanel.show(...)` so the
/// surface protocol stays small.
@MainActor
struct PanelShowConfig {
    let settings: AppSettings
    let overrides: SessionOverrides
    let displayedTurn: DisplayedTurn?
    let outputDestinations: [OutputDestination]
    let initialAppName: String?
    let audioRecorder: AudioRecorder?
    let minimized: Bool
}

/// Boundary between `CaptureSession` and the real `CapturePanel` (NSPanel).
///
/// The session never holds an NSPanel directly. All panel interactions go through
/// this protocol, which has two concrete implementations:
///
///  - `CapturePanelAdapter` — production, wraps the real `CapturePanel`.
///  - `FakeCapturePanel` — test double, records every call for assertions.
///
/// Callbacks are declared as `var` properties rather than `show()` parameters so
/// the session can rewire them at any time and so the test double can fire them
/// imperatively from the outside (e.g. `fake.onConfirm?()`).
@MainActor
protocol CapturePanelSurface: AnyObject {
    var isVisible: Bool { get }
    var isMinimized: Bool { get }

    // Lifecycle
    func show(config: PanelShowConfig)
    func dismiss()
    func orderOut()
    func orderBack()
    func minimize()
    func buzz()

    // Content
    func populateImmediateActionText(segments: [InputSegment])
    func setPhase(_ phase: CaptureViewModel.CapturePhase)
    func setPreparationNotice(_ message: String?)
    func showPreview(text: String, modeName: String?)
    func setError(_ message: String)
    func setAIProcessingError(_ message: String)
    func signalClipboardCapture()
    func setSuspendedForModeSwitcher(_ suspended: Bool)
    func setCursorContextAvailable(_ available: Bool)

    // Callbacks — the session assigns these and the panel fires them.
    var onFocusLost: (() -> Void)? { get set }
    var onConfirm: (() -> Void)? { get set }
    var onCancelCapture: (() -> Void)? { get set }
    var onDestinationSubmit: ((UUID) -> Void)? { get set }
    var onRetryAIProcessing: (() -> Void)? { get set }
}

// MARK: - Production Adapter

/// Thin wrapper around `CapturePanel` that forwards protocol calls to the
/// existing NSPanel-backed implementation. Contains no orchestration logic.
@MainActor
final class CapturePanelAdapter: CapturePanelSurface {
    private let panel: CapturePanel

    var onFocusLost: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancelCapture: (() -> Void)?
    var onDestinationSubmit: ((UUID) -> Void)?
    var onRetryAIProcessing: (() -> Void)?

    init(_ panel: CapturePanel) {
        self.panel = panel
    }

    var isVisible: Bool { panel.isVisible }
    var isMinimized: Bool { panel.isMinimized }

    func show(config: PanelShowConfig) {
        panel.show(
            settings: config.settings,
            overrides: config.overrides,
            displayedTurn: config.displayedTurn,
            outputDestinations: config.outputDestinations,
            initialAppName: config.initialAppName,
            audioRecorder: config.audioRecorder,
            minimized: config.minimized,
            onDismiss: { [weak self] in self?.onFocusLost?() },
            onConfirm: { [weak self] in self?.onConfirm?() },
            onCancelCapture: { [weak self] in self?.onCancelCapture?() },
            onDestinationSubmit: { [weak self] destID in self?.onDestinationSubmit?(destID) }
        )
        panel.onFocusLost = { [weak self] in self?.onFocusLost?() }
        panel.viewModel?.onRetryAIProcessing = { [weak self] in self?.onRetryAIProcessing?() }
    }

    func dismiss() {
        panel.onFocusLost = nil
        panel.dismiss()
    }

    func orderOut() { panel.orderOut() }
    func orderBack() { panel.orderBack() }
    func minimize() { panel.minimize() }
    func buzz() { panel.buzz() }

    func populateImmediateActionText(segments: [InputSegment]) {
        panel.populateImmediateActionText(inputSegments: segments)
    }

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        panel.setPhase(phase)
    }

    func setPreparationNotice(_ message: String?) {
        panel.setPreparationNotice(message)
    }

    func showPreview(text: String, modeName: String?) {
        panel.showPreview(text: text, modeName: modeName)
    }

    func setError(_ message: String) {
        panel.setError(message)
    }

    func setAIProcessingError(_ message: String) {
        panel.setAIProcessingError(message)
        // The view model may have been (re)built by setAIProcessingError's internal path;
        // rewire the retry callback so the user's "Retry" tap reaches the session.
        panel.viewModel?.onRetryAIProcessing = { [weak self] in self?.onRetryAIProcessing?() }
    }

    func signalClipboardCapture() {
        panel.signalClipboardCapture()
    }

    func setSuspendedForModeSwitcher(_ suspended: Bool) {
        panel.viewModel?.isSuspendedForModeSwitcher = suspended
        if suspended {
            panel.orderOut()
        } else if panel.isVisible {
            panel.orderBack()
        }
    }

    func setCursorContextAvailable(_ available: Bool) {
        panel.viewModel?.cursorContextAvailable = available
    }
}
