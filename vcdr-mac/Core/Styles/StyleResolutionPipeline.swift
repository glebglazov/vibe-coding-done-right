import Foundation
import Combine
import OSLog

// MARK: - StyleResolution Protocol

/// Protocol for style resolution operations.
/// Allows for mocking in tests.
public protocol StyleResolution: Sendable {
    /// The currently resolved effective style.
    var currentStyle: Style { get }

    /// The style that would be active without any override (based on frontmost app).
    var resolvedStyleWithoutOverride: Style { get }

    /// Whether a temporary style override is currently active.
    var hasActiveOverride: Bool { get }

    /// Stream of resolved style changes.
    var styleStream: AsyncStream<Style> { get }

    /// Sets a temporary style override.
    /// - Parameter styleID: The style ID to override with, or nil to clear.
    func setStyleOverride(_ styleID: UUID?)

    /// Clears any active style override.
    func clearOverride()

    /// Starts the resolution pipeline.
    func start() async

    /// Stops the resolution pipeline.
    func stop()
}

// MARK: - StyleResolutionPipeline

/// Resolves the effective style based on frontmost app and user overrides.
///
/// Resolution priority:
/// 1. Temporary override (if active)
/// 2. App-specific style match (from StyleRegistry)
/// 3. Default style (first in registry)
///
/// This class bridges the FrontmostAppMonitor with the StyleRegistry,
/// providing a unified stream of resolved styles for UI consumption.
@MainActor
public final class StyleResolutionPipeline: StyleResolution {

    // MARK: - Properties

    /// The currently resolved effective style (including any override).
    @Published
    public private(set) var currentStyle: Style

    /// The style that would be active without any override.
    @Published
    public private(set) var resolvedStyleWithoutOverride: Style

    /// Whether a temporary style override is currently active.
    public var hasActiveOverride: Bool { activeOverrideID != nil }

    /// Stream of resolved style changes.
    public var styleStream: AsyncStream<Style> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            let id = UUID()
            self.streamContinuations[id] = continuation
            // Yield current value immediately
            continuation.yield(self.currentStyle)

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Callback invoked when the effective style changes.
    public var onStyleChanged: ((Style) -> Void)?

    /// Callback invoked when accessibility permission state changes.
    public var onAccessibilityPermissionChanged: ((Bool) -> Void)?

    private let styleRegistry: StyleRegistry
    private var frontmostAppMonitor: any FrontmostAppMonitoring
    private var streamContinuations: [UUID: AsyncStream<Style>.Continuation] = [:]
    private var monitorTask: Task<Void, Never>?
    private var isRunning = false

    /// The active temporary override style ID, if any.
    private var activeOverrideID: UUID?

    /// The current frontmost app bundle ID, if known.
    private var currentFrontmostBundleID: String?

    // MARK: - Initialization

    /// Creates a new style resolution pipeline.
    /// - Parameters:
    ///   - styleRegistry: The style registry for looking up styles.
    ///   - frontmostAppMonitor: The monitor for frontmost app changes.
    ///   - initialStyle: The initial style to use before resolution starts (defaults to Casual).
    public init(
        styleRegistry: StyleRegistry,
        frontmostAppMonitor: any FrontmostAppMonitoring,
        initialStyle: Style? = nil
    ) {
        self.styleRegistry = styleRegistry
        self.frontmostAppMonitor = frontmostAppMonitor

        // Initialize with provided or default style
        let style = initialStyle ?? Style.casual
        self.currentStyle = style
        self.resolvedStyleWithoutOverride = style
    }

    // MARK: - Public Methods

    /// Starts the resolution pipeline.
    ///
    /// Begins monitoring frontmost app changes and resolving styles.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        // Set up permission change callback
        self.frontmostAppMonitor.onPermissionChanged = { [weak self] granted in
            guard let self else { return }
            Task { @MainActor in
                self.handlePermissionChanged(granted)
            }
        }

        // Start the frontmost app monitor
        await frontmostAppMonitor.startMonitoring()

        // Start consuming the bundle ID stream
        startMonitoringStream()

        // Perform initial resolution
        await performResolution()

        Logger.styles.info("StyleResolutionPipeline started")
    }

    /// Stops the resolution pipeline.
    public func stop() {
        isRunning = false

        monitorTask?.cancel()
        monitorTask = nil

        frontmostAppMonitor.stopMonitoring()
        self.frontmostAppMonitor.onPermissionChanged = nil
        onStyleChanged = nil
        onAccessibilityPermissionChanged = nil

        // Finish all stream continuations
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()

        Logger.styles.info("StyleResolutionPipeline stopped")
    }

    /// Sets a temporary style override.
    ///
    /// The override takes precedence over app-specific styles until cleared.
    /// This is used for the style switcher (TAB key) and menu bar selection.
    ///
    /// - Parameter styleID: The style ID to override with, or nil to clear.
    public func setStyleOverride(_ styleID: UUID?) {
        let previousOverride = activeOverrideID
        activeOverrideID = styleID

        if styleID != previousOverride {
            if let id = styleID {
                Logger.styles.info("Style override set: \(id)")
            } else {
                Logger.styles.info("Style override cleared")
            }

            Task {
                await performResolution()
            }
        }
    }

    /// Clears any active style override.
    public func clearOverride() {
        setStyleOverride(nil)
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

        // Re-resolve in case we need to fall back to default
        Task {
            await performResolution()
        }
    }

    private func performResolution() async {
        // Determine the style based on resolution priority:
        // 1. Override (if active)
        // 2. App match from registry
        // 3. Default style

        let resolvedStyle: Style

        if let overrideID = self.activeOverrideID,
           let overrideStyle = await styleRegistry.style(withID: overrideID) {
            // Priority 1: Temporary override
            resolvedStyle = overrideStyle
        } else if let bundleID = currentFrontmostBundleID {
            // Priority 2: App-specific style match
            resolvedStyle = await styleRegistry.style(forBundleID: bundleID)
        } else {
            // Priority 3: Default style (when no bundle ID available)
            resolvedStyle = await styleRegistry.defaultStyle()
        }

        // Update the "without override" style (what the app match would be)
        if let bundleID = currentFrontmostBundleID {
            resolvedStyleWithoutOverride = await styleRegistry.style(forBundleID: bundleID)
        } else {
            resolvedStyleWithoutOverride = await styleRegistry.defaultStyle()
        }

        // Only notify if the effective style changed
        guard resolvedStyle.id != currentStyle.id else { return }

        currentStyle = resolvedStyle

        // Notify stream continuations
        for (_, continuation) in streamContinuations {
            continuation.yield(resolvedStyle)
        }

        // Notify callback
        onStyleChanged?(resolvedStyle)

        Logger.styles.info("Resolved style: \(resolvedStyle.name) (override: \(self.activeOverrideID != nil))")
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

    /// Creates a mock pipeline with an initial style.
    /// - Parameter initialStyle: The initial style to use. Defaults to Casual if not specified.
    public init(initialStyle: Style? = nil) {
        let style = initialStyle ?? Style.casual
        self.currentStyle = style
        self.resolvedStyleWithoutOverride = style
    }

    /// Simulate a style change (as if from frontmost app change).
    public func simulateStyleChange(_ style: Style) {
        currentStyle = style
        resolvedStyleWithoutOverride = style

        for (_, continuation) in streamContinuations {
            continuation.yield(style)
        }

        onStyleChanged?(style)
    }

    public func setStyleOverride(_ styleID: UUID?) {
        self.overrideID = styleID
        self.hasActiveOverride = styleID != nil

        // In a real scenario, we'd re-resolve, but for mock we just track the override
        Logger.styles.debug("Mock override set: \(String(describing: styleID))")
    }

    public func clearOverride() {
        setStyleOverride(nil)
    }

    public func start() async {
        // No-op for mock
    }

    public func stop() {
        // Finish all continuations
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }
}

#endif