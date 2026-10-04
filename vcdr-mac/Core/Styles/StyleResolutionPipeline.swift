import Foundation
import Combine
import OSLog

// MARK: - StyleResolution Protocol

/// Single authority for Detected Style, Style Override, and Effective Style.
public protocol StyleResolution: Sendable {
    /// Effective Style: override when active, otherwise Detected Style.
    var currentStyle: Style { get }

    /// Detected Style from the frontmost app, ignoring any override.
    var resolvedStyleWithoutOverride: Style { get }

    /// Whether a Style Override is currently active.
    var hasActiveOverride: Bool { get }

    /// Stream of Effective Style changes.
    var styleStream: AsyncStream<Style> { get }

    /// Sets a Style Override by ID, or clears it when nil.
    func setStyleOverride(_ styleID: UUID?)

    /// Activates a Style Override with a resolved Style value.
    func activateOverride(_ style: Style)

    /// Clears any active Style Override.
    func clearOverride()

    /// Cycles Style Override through detected and built-in styles.
    @discardableResult
    func cycleToNextStyle() -> Style

    /// Starts frontmost-app monitoring and style resolution.
    func start() async

    /// Stops frontmost-app monitoring and style resolution.
    func stop()
}

// MARK: - StyleResolutionPipeline

/// Owns Detected Style, Style Override, and Effective Style.
///
/// Resolution priority for Effective Style:
/// 1. Style Override (if active)
/// 2. App-specific style match (from StyleRegistry)
/// 3. Default style
@MainActor
public final class StyleResolutionPipeline: StyleResolution {

    // MARK: - Properties

    /// Effective Style (override when active, otherwise Detected Style).
    @Published
    public private(set) var currentStyle: Style

    /// Detected Style from the frontmost app, ignoring any override.
    @Published
    public private(set) var resolvedStyleWithoutOverride: Style

    /// Whether a Style Override is currently active.
    public var hasActiveOverride: Bool { activeOverrideID != nil }

    /// Stream of Effective Style changes.
    public var styleStream: AsyncStream<Style> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            let id = UUID()
            self.streamContinuations[id] = continuation
            continuation.yield(self.currentStyle)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Callback invoked when Effective Style changes.
    public var onStyleChanged: ((Style) -> Void)?

    /// Callback invoked when accessibility permission state changes.
    public var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    private let styleRegistry: StyleRegistry
    private let availableStyles: [Style]
    private var frontmostAppMonitor: any FrontmostAppMonitoring
    private var streamContinuations: [UUID: AsyncStream<Style>.Continuation] = [:]
    private var monitorTask: Task<Void, Never>?
    private var isRunning = false

    /// Active Style Override ID, if any. Saved on every change, so the
    /// user's pick survives a relaunch.
    private var activeOverrideID: UUID? {
        didSet { userDefaults.set(activeOverrideID?.uuidString, forKey: Self.activeOverrideIDKey) }
    }

    private static let activeOverrideIDKey = "activeStyleOverrideID"
    private let userDefaults: UserDefaults

    /// The current frontmost app bundle ID, if known.
    private var currentFrontmostBundleID: String?

    // MARK: - Initialization

    public init(
        styleRegistry: StyleRegistry,
        frontmostAppMonitor: any FrontmostAppMonitoring,
        userDefaults: UserDefaults,
        availableStyles: [Style]? = nil,
        initialStyle: Style? = nil
    ) {
        self.styleRegistry = styleRegistry
        self.frontmostAppMonitor = frontmostAppMonitor
        self.userDefaults = userDefaults
        self.availableStyles = availableStyles ?? Style.builtIn
        self.activeOverrideID = userDefaults.string(forKey: Self.activeOverrideIDKey).flatMap(UUID.init(uuidString:))

        let style = initialStyle ?? Style.casual
        self.currentStyle = style
        self.resolvedStyleWithoutOverride = style
    }

    // MARK: - Public Methods

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        frontmostAppMonitor.onPermissionChanged = { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                self.handlePermissionChanged(granted)
            }
        }

        await frontmostAppMonitor.startMonitoring()
        startMonitoringStream()
        await performResolution()

        Logger.styles.info("StyleResolutionPipeline started")
    }

    public func stop() {
        isRunning = false

        monitorTask?.cancel()
        monitorTask = nil

        frontmostAppMonitor.stopMonitoring()
        frontmostAppMonitor.onPermissionChanged = nil
        onStyleChanged = nil
        onAccessibilityPermissionChanged = nil

        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()

        Logger.styles.info("StyleResolutionPipeline stopped")
    }

    public func setStyleOverride(_ styleID: UUID?) {
        let previousOverride = activeOverrideID
        activeOverrideID = styleID

        guard styleID != previousOverride else { return }

        if let id = styleID {
            Logger.styles.info("Style override set: \(id)")
        } else {
            Logger.styles.info("Style override cleared")
            applyEffectiveStyle(resolvedStyleWithoutOverride)
            return
        }

        Task {
            await performResolution()
        }
    }

    public func activateOverride(_ style: Style) {
        let previousOverride = activeOverrideID
        activeOverrideID = style.id

        guard style.id != previousOverride else { return }

        Logger.styles.info("Style override activated: \(style.name)")
        applyEffectiveStyle(style)
    }

    public func clearOverride() {
        guard activeOverrideID != nil else { return }
        activeOverrideID = nil
        Logger.styles.info("Style override cleared")
        applyEffectiveStyle(resolvedStyleWithoutOverride)
    }

    @discardableResult
    public func cycleToNextStyle() -> Style {
        var cycleOrder: [Style] = [resolvedStyleWithoutOverride]
        for style in availableStyles where style.id != resolvedStyleWithoutOverride.id {
            cycleOrder.append(style)
        }

        let current = hasActiveOverride ? currentStyle : resolvedStyleWithoutOverride
        let currentIndex = cycleOrder.firstIndex(where: { $0.id == current.id }) ?? 0
        let nextIndex = (currentIndex + 1) % cycleOrder.count

        if nextIndex == 0 {
            clearOverride()
        } else {
            activateOverride(cycleOrder[nextIndex])
        }

        return currentStyle
    }

    /// Returns the display name for the current Effective Style state.
    public func styleDisplayName() -> String {
        if hasActiveOverride {
            return "\(currentStyle.name) (overridden)"
        }
        return currentStyle.name
    }

    // MARK: - Private Methods

    private func startMonitoringStream() {
        monitorTask?.cancel()
        monitorTask = Task {
            let stream = frontmostAppMonitor.bundleIDStream

            for await bundleID in stream {
                guard !Task.isCancelled else { break }
                await handleFrontmostAppChanged(bundleID)
            }
        }
    }

    private func handleFrontmostAppChanged(_ bundleID: String?) async {
        currentFrontmostBundleID = bundleID
        await performResolution()
    }

    private func handlePermissionChanged(_ granted: Bool) {
        onAccessibilityPermissionChanged?(granted)

        if !granted {
            Logger.styles.warning("Accessibility permission denied, falling back to default style")
        }

        Task {
            await performResolution()
        }
    }

    private func performResolution() async {
        let detectedStyle: Style
        if let bundleID = currentFrontmostBundleID {
            detectedStyle = await styleRegistry.style(forBundleID: bundleID)
        } else {
            detectedStyle = await styleRegistry.defaultStyle()
        }
        resolvedStyleWithoutOverride = detectedStyle

        let effectiveStyle: Style
        if let overrideID = activeOverrideID,
           let overrideStyle = await styleRegistry.style(withID: overrideID) {
            effectiveStyle = overrideStyle
        } else {
            effectiveStyle = detectedStyle
        }

        applyEffectiveStyle(effectiveStyle)

        Logger.styles.info(
            "Resolved style: \(effectiveStyle.name) (override: \(self.activeOverrideID != nil))"
        )
    }

    private func applyEffectiveStyle(_ style: Style) {
        guard style.id != currentStyle.id else { return }

        currentStyle = style
        notifyEffectiveStyleChanged(style)
    }

    private func notifyEffectiveStyleChanged(_ style: Style) {
        for (_, continuation) in streamContinuations {
            continuation.yield(style)
        }
        onStyleChanged?(style)
    }
}

// MARK: - Mock Implementation for Testing

#if DEBUG

/// Mock style resolution pipeline for testing.
@MainActor
public final class MockStyleResolutionPipeline: StyleResolution {

    @Published
    public private(set) var currentStyle: Style

    @Published
    public private(set) var resolvedStyleWithoutOverride: Style

    public private(set) var hasActiveOverride: Bool = false

    public var styleStream: AsyncStream<Style> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            let id = UUID()
            self.streamContinuations[id] = continuation
            continuation.yield(self.currentStyle)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public var onStyleChanged: ((Style) -> Void)?
    public var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    private var streamContinuations: [UUID: AsyncStream<Style>.Continuation] = [:]
    private var overrideID: UUID?
    private let availableStyles: [Style]

    public init(initialStyle: Style? = nil, availableStyles: [Style]? = nil) {
        let style = initialStyle ?? Style.casual
        self.currentStyle = style
        self.resolvedStyleWithoutOverride = style
        self.availableStyles = availableStyles ?? Style.builtIn
    }

    public func simulateStyleChange(_ style: Style) {
        resolvedStyleWithoutOverride = style
        if !hasActiveOverride {
            currentStyle = style
            notifyEffectiveStyleChanged(style)
        } else {
            onStyleChanged?(currentStyle)
        }
    }

    public func setStyleOverride(_ styleID: UUID?) {
        overrideID = styleID
        hasActiveOverride = styleID != nil

        if let styleID,
           let style = availableStyles.first(where: { $0.id == styleID }) {
            currentStyle = style
            notifyEffectiveStyleChanged(style)
        } else if !hasActiveOverride {
            currentStyle = resolvedStyleWithoutOverride
            notifyEffectiveStyleChanged(currentStyle)
        }
    }

    public func activateOverride(_ style: Style) {
        setStyleOverride(style.id)
    }

    public func clearOverride() {
        setStyleOverride(nil)
    }

    @discardableResult
    public func cycleToNextStyle() -> Style {
        var cycleOrder: [Style] = [resolvedStyleWithoutOverride]
        for style in availableStyles where style.id != resolvedStyleWithoutOverride.id {
            cycleOrder.append(style)
        }

        let current = hasActiveOverride ? currentStyle : resolvedStyleWithoutOverride
        let currentIndex = cycleOrder.firstIndex(where: { $0.id == current.id }) ?? 0
        let nextIndex = (currentIndex + 1) % cycleOrder.count

        if nextIndex == 0 {
            clearOverride()
        } else {
            activateOverride(cycleOrder[nextIndex])
        }

        return currentStyle
    }

    public func start() async {}

    public func stop() {
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }

    private func notifyEffectiveStyleChanged(_ style: Style) {
        for (_, continuation) in streamContinuations {
            continuation.yield(style)
        }
        onStyleChanged?(style)
    }
}

#endif
