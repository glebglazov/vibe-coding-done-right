import Foundation
@testable import vcdr_mac

/// Test double for `CapturePanelSurface`. Records every call into a `[Call]`
/// array so tests can assert ordering, and exposes `fire…()` helpers so tests
/// can imperatively trigger panel callbacks (confirm, cancel, destination
/// submit, retry, focus-lost) from the outside.
///
/// Deliberately holds no SwiftUI / NSPanel state — any test that tries to
/// boot a real NSPanel would fail in an XCTest process.
@MainActor
final class FakeCapturePanel: CapturePanelSurface {

    // MARK: - Call log

    enum Call: Equatable {
        case show
        case dismiss
        case orderOut
        case orderBack
        case minimize
        case buzz
        case populateImmediateActionText(count: Int)
        case setPhase(CaptureViewModel.CapturePhase)
        case showPreview(text: String, modeName: String?)
        case setError(String)
        case setAIProcessingError(String)
        case signalClipboardCapture
        case setSuspendedForModeSwitcher(Bool)
    }

    private(set) var calls: [Call] = []

    // MARK: - Mutable state exposed for assertions

    var isVisible: Bool = false
    var isMinimized: Bool = false
    var lastShownConfig: PanelShowConfig?
    var lastPreviewText: String?
    var lastErrorMessage: String?
    var lastAIErrorMessage: String?

    // MARK: - CapturePanelSurface methods

    func show(config: PanelShowConfig) {
        calls.append(.show)
        lastShownConfig = config
        isVisible = true
        isMinimized = config.minimized
    }

    func dismiss() {
        calls.append(.dismiss)
        isVisible = false
        isMinimized = false
    }

    func orderOut() { calls.append(.orderOut) }
    func orderBack() { calls.append(.orderBack) }

    func minimize() {
        calls.append(.minimize)
        isMinimized = true
    }

    func buzz() { calls.append(.buzz) }

    func populateImmediateActionText(segments: [InputSegment]) {
        calls.append(.populateImmediateActionText(count: segments.count))
    }

    func setPhase(_ phase: CaptureViewModel.CapturePhase) {
        calls.append(.setPhase(phase))
    }

    func showPreview(text: String, modeName: String?) {
        calls.append(.showPreview(text: text, modeName: modeName))
        lastPreviewText = text
    }

    func setError(_ message: String) {
        calls.append(.setError(message))
        lastErrorMessage = message
    }

    func setAIProcessingError(_ message: String) {
        calls.append(.setAIProcessingError(message))
        lastAIErrorMessage = message
    }

    func signalClipboardCapture() {
        calls.append(.signalClipboardCapture)
    }

    func setSuspendedForModeSwitcher(_ suspended: Bool) {
        calls.append(.setSuspendedForModeSwitcher(suspended))
    }

    // MARK: - Callbacks (set by CaptureSession, fired by tests)

    var onFocusLost: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancelCapture: (() -> Void)?
    var onDestinationSubmit: ((UUID) -> Void)?
    var onRetryAIProcessing: (() -> Void)?

    func fireConfirm() { onConfirm?() }
    func fireCancelCapture() { onCancelCapture?() }
    func fireDestinationSubmit(_ id: UUID) { onDestinationSubmit?(id) }
    func fireRetryAIProcessing() { onRetryAIProcessing?() }
    func fireFocusLost() { onFocusLost?() }
}
