import Combine
import Foundation
import OSLog

// MARK: - StyleOverrideController Protocol

/// Protocol for style override management.
/// Allows for mocking in tests.
public protocol StyleOverrideControlling: Sendable {
    /// The currently active style override, or nil if using detected style.
    var activeOverride: Style? { get }

    /// Whether a style override is currently active.
    var isOverridden: Bool { get }

    /// The effective style to use (override or detected).
    var currentEffectiveStyle: Style { get }

    /// Stream of effective style changes.
    var styleStream: AsyncStream<Style> { get }

    /// Activates a temporary style override.
    /// - Parameter style: The style to override with.
    func activateOverride(_ style: Style)

    /// Clears any active style override.
    func clearOverride()

    /// Updates the detected style based on frontmost app.
    /// - Parameter style: The auto-detected style.
    func updateDetectedStyle(_ style: Style)
}

// MARK: - StyleOverrideController

/// Manages transient style override functionality for the mode switcher.
///
/// This controller maintains the override state and handles lifecycle events:
/// - Override clears on frontmost app change
/// - Override clears on recording stop
/// - Next recording session starts fresh with detected style
///
/// The resolution priority is:
/// 1. Active override (if set)
/// 2. Detected style from frontmost app
/// 3. Default style (fallback)
@MainActor
public final class StyleOverrideController: StyleOverrideControlling {

    // MARK: - Properties

    /// The currently active style override, or nil if using detected style.
    @Published
    public private(set) var activeOverride: Style?

    /// Whether a style override is currently active.
    public var isOverridden: Bool { activeOverride != nil }

    /// The currently detected style from frontmost app (without override).
    @Published
    public private(set) var detectedStyle: Style

    /// The effective style to use (override takes precedence over detected).
    public var currentEffectiveStyle: Style {
        activeOverride ?? detectedStyle
    }

    /// Stream of effective style changes.
    public var styleStream: AsyncStream<Style> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            let id = UUID()
            self.streamContinuations[id] = continuation

            // Yield current value immediately
            continuation.yield(self.currentEffectiveStyle)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Callback invoked when the effective style changes.
    public var onStyleChanged: ((Style) -> Void)?

    /// All available styles for cycling.
    private let availableStyles: [Style]

    private var streamContinuations: [UUID: AsyncStream<Style>.Continuation] = [:]
    private var lastEffectiveStyle: Style

    // MARK: - Initialization

    /// Creates a new style override controller.
    /// - Parameters:
    ///   - availableStyles: All available styles for cycling.
    ///   - initialDetectedStyle: The initial detected style (defaults to Casual).
    public init(
        availableStyles: [Style]? = nil,
        initialDetectedStyle: Style? = nil
    ) {
        // Resolve default values on MainActor to avoid isolation warnings
        let resolvedAvailableStyles = availableStyles ?? MainActor.assumeIsolated { Style.builtIn }
        self.availableStyles = resolvedAvailableStyles
        let initialStyle = initialDetectedStyle ?? MainActor.assumeIsolated { Style.casual }
        self.detectedStyle = initialStyle
        self.lastEffectiveStyle = initialStyle
    }

    // MARK: - Public Methods

    /// Activates a temporary style override.
    ///
    /// The override takes precedence over the detected style until cleared.
    /// - Parameter style: The style to override with.
    public func activateOverride(_ style: Style) {
        let previousStyle = currentEffectiveStyle
        activeOverride = style

        Logger.styles.info("Style override activated: \(style.name)")

        // Only notify if effective style changed
        if currentEffectiveStyle.id != previousStyle.id {
            notifyStyleChanged()
        }
    }

    /// Clears any active style override.
    ///
    /// After clearing, the detected style becomes effective again.
    public func clearOverride() {
        guard activeOverride != nil else { return }

        let previousStyle = currentEffectiveStyle
        activeOverride = nil

        Logger.styles.info("Style override cleared, reverting to: \(self.detectedStyle.name)")

        // Only notify if effective style changed
        if currentEffectiveStyle.id != previousStyle.id {
            notifyStyleChanged()
        }
    }

    /// Updates the detected style based on frontmost app.
    ///
    /// Called by the frontmost app monitor when the active app changes.
    /// Automatically clears any active override.
    /// - Parameter style: The auto-detected style.
    public func updateDetectedStyle(_ style: Style) {
        guard style.id != detectedStyle.id else { return }

        let previousStyle = currentEffectiveStyle
        detectedStyle = style

        // Clear override when frontmost app changes (per acceptance criteria)
        if activeOverride != nil {
            activeOverride = nil
            Logger.styles.info("Cleared style override due to frontmost app change")
        }

        Logger.styles.debug("Detected style updated to: \(style.name)")

        // Only notify if effective style changed
        if currentEffectiveStyle.id != previousStyle.id {
            notifyStyleChanged()
        }
    }

    /// Cycles to the next style in the available styles list.
    ///
    /// The cycle order is: detected → Casual → Formal → detected (if those are the available styles)
    /// - Returns: The newly selected style.
    @discardableResult
    public func cycleToNextStyle() -> Style {
        // Build the cycle order: detected first, then all available styles except detected
        var cycleOrder: [Style] = [detectedStyle]
        for style in availableStyles where style.id != detectedStyle.id {
            cycleOrder.append(style)
        }

        // Find current position
        let currentStyle = activeOverride ?? detectedStyle
        let currentIndex = cycleOrder.firstIndex(where: { $0.id == currentStyle.id }) ?? 0

        // Move to next, wrapping around
        let nextIndex = (currentIndex + 1) % cycleOrder.count
        let nextStyle = cycleOrder[nextIndex]

        if nextIndex == 0 {
            // Cycling back to detected style - clear override
            clearOverride()
        } else {
            activateOverride(nextStyle)
        }

        return currentEffectiveStyle
    }

    /// Returns the display name for the current style state.
    ///
    /// - Returns: The style name, with "(overridden)" suffix if applicable.
    public func styleDisplayName() -> String {
        if isOverridden {
            return "\(currentEffectiveStyle.name) (overridden)"
        }
        return currentEffectiveStyle.name
    }

    // MARK: - Private Methods

    private func notifyStyleChanged() {
        let newStyle = currentEffectiveStyle
        lastEffectiveStyle = newStyle

        // Notify all stream continuations
        for (_, continuation) in streamContinuations {
            continuation.yield(newStyle)
        }

        // Notify callback
        onStyleChanged?(newStyle)

        Logger.styles.info("Effective style changed to: \(newStyle.name) (overridden: \(self.isOverridden))")
    }
}

// MARK: - Mock Implementation for Testing

#if DEBUG

/// Mock style override controller for testing.
@MainActor
public final class MockStyleOverrideController: StyleOverrideControlling {

    @Published
    public private(set) var activeOverride: Style?

    public var isOverridden: Bool { activeOverride != nil }

    @Published
    public private(set) var detectedStyle: Style

    public var currentEffectiveStyle: Style {
        activeOverride ?? detectedStyle
    }

    public var styleStream: AsyncStream<Style> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            let id = UUID()
            self.streamContinuations[id] = continuation
            continuation.yield(self.currentEffectiveStyle)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public var onStyleChanged: ((Style) -> Void)?

    private var streamContinuations: [UUID: AsyncStream<Style>.Continuation] = [:]

    /// Creates a mock controller with optional initial values.
    public init(
        detectedStyle: Style? = nil,
        override: Style? = nil
    ) {
        self.detectedStyle = detectedStyle ?? MainActor.assumeIsolated { Style.casual }
        self.activeOverride = override
    }

    /// Simulate a detected style change (as if from frontmost app change).
    public func simulateDetectedStyleChange(_ style: Style) {
        detectedStyle = style
        activeOverride = nil  // Override clears on app change

        for (_, continuation) in streamContinuations {
            continuation.yield(currentEffectiveStyle)
        }
        onStyleChanged?(currentEffectiveStyle)
    }

    public func activateOverride(_ style: Style) {
        activeOverride = style

        for (_, continuation) in streamContinuations {
            continuation.yield(style)
        }
        onStyleChanged?(style)
    }

    public func clearOverride() {
        activeOverride = nil

        for (_, continuation) in streamContinuations {
            continuation.yield(detectedStyle)
        }
        onStyleChanged?(detectedStyle)
    }

    public func updateDetectedStyle(_ style: Style) {
        simulateDetectedStyleChange(style)
    }
}

#endif
