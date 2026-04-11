import Foundation
import OSLog

// MARK: - StyleRegistry Protocol

/// Protocol for style registry operations.
/// Allows for mocking in tests and platform-specific implementations.
public protocol StyleRegistryProtocol: Sendable {
    /// Returns all styles in their current order.
    func allStyles() async -> [Style]
    
    /// Returns the style for a given bundle ID, or the default style if no match.
    func style(forBundleID bundleID: String) async -> Style
    
    /// Sets the default style by moving it to the first position.
    func setDefault(_ style: Style) async
    
    /// Moves an app from its current style (if any) to the specified style.
    func moveApp(bundleID: String, toStyle style: Style) async
    
    /// Reorders styles by moving items at the specified indices to the new position.
    func reorderStyles(from indices: IndexSet, to newOffset: Int) async
}

// MARK: - Persistence Models

/// Codable container for style registry persistence.
/// This structure represents the on-disk format and handles versioning/migration.
private struct StyleRegistryStorage: Codable, Equatable {
    /// Version number for future migration support.
    var version: Int
    
    /// Ordered list of style IDs. The first style is the default.
    var styleIDs: [UUID]
    
    /// Map of bundle ID to assigned style ID.
    var appAssignments: [String: UUID]
    
    /// Style definitions (id -> Style).
    var styles: [UUID: Style]
    
    static let currentVersion = 1
    static let empty = StyleRegistryStorage(
        version: currentVersion,
        styleIDs: [],
        appAssignments: [:],
        styles: [:]
    )
}

// MARK: - StyleRegistry Actor

/// Actor that manages style persistence, ordering, and app-to-style assignments.
/// 
/// Thread-safe operations ensure consistent state across concurrent access.
/// All mutations are persisted to UserDefaults.
///
/// ## Behavior
/// - First style in the list is the default (isDefault computed property)
/// - Duplicate prevention: adding app to Style A automatically removes from Style B
/// - Built-in styles are auto-created on first launch with stable UUIDs
public actor StyleRegistry: StyleRegistryProtocol {
    
    // MARK: - Constants
    
    private static let userDefaultsKey = "vcdr.styleRegistry"
    private static let firstLaunchKey = "vcdr.styleRegistry.firstLaunch"
    
    // MARK: - Properties
    
    private let userDefaults: UserDefaults
    private var storage: StyleRegistryStorage
    
    /// Ordered list of styles. The first style is the default.
    private var styles: [Style] {
        didSet {
            updateStorageFromStyles()
            persist()
        }
    }
    
    // MARK: - Initialization
    
    /// Creates a new StyleRegistry with the specified UserDefaults instance.
    /// - Parameter userDefaults: The UserDefaults instance to use for persistence.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.storage = StyleRegistryStorage.empty
        
        // Load or initialize storage
        if let loaded = Self.loadStorage(from: userDefaults) {
            self.storage = loaded
        }
        
        // Convert storage to ordered styles array
        self.styles = Self.orderedStyles(from: storage)
        
        // First launch: initialize with built-in styles
        let isFirstLaunch = !userDefaults.bool(forKey: Self.firstLaunchKey)
        if isFirstLaunch {
            initializeBuiltInStyles()
            userDefaults.set(true, forKey: Self.firstLaunchKey)
        }
        
        // Ensure built-in styles exist (migration/recovery)
        ensureBuiltInStylesExist()
        
        // Sync isDefault flags with current order
        syncDefaultFlags()
    }
    
    // MARK: - StyleRegistryProtocol
    
    /// Returns all styles in their current order.
    public func allStyles() -> [Style] {
        return styles
    }
    
    /// Returns the style for a given bundle ID.
    /// Returns the first matching style by list order, or the default if no match.
    /// - Parameter bundleID: The bundle identifier of the application.
    /// - Returns: The matching style, or the default style.
    public func style(forBundleID bundleID: String) -> Style {
        // Find the first style that has this bundle ID assigned
        for style in styles {
            if style.associatedAppBundleIDs.contains(bundleID) {
                return style
            }
        }
        // Return default (first style) if no match
        return defaultStyle()
    }
    
    /// Sets the default style by moving it to the first position.
    /// - Parameter style: The style to make default.
    public func setDefault(_ style: Style) {
        guard let currentIndex = styles.firstIndex(where: { $0.id == style.id }) else {
            Logger.styles.warning("Attempted to set non-existent style as default: \(style.name)")
            return
        }
        
        guard currentIndex != 0 else { return }
        
        var newStyles = styles
        let movedStyle = newStyles.remove(at: currentIndex)
        newStyles.insert(movedStyle, at: 0)
        
        styles = newStyles
        syncDefaultFlags()
        
        Logger.styles.info("Set '\(style.name)' as default style")
    }
    
    /// Moves an app from its current style (if any) to the specified style.
    /// Automatically removes the app from any other style (duplicate prevention).
    /// - Parameters:
    ///   - bundleID: The bundle identifier of the application.
    ///   - style: The target style.
    public func moveApp(bundleID: String, toStyle targetStyle: Style) {
        guard let targetIndex = styles.firstIndex(where: { $0.id == targetStyle.id }) else {
            Logger.styles.warning("Attempted to move app to non-existent style: \(targetStyle.name)")
            return
        }
        
        var newStyles = styles
        var movedFromStyle: Style? = nil
        
        // Remove from any style that has this app (duplicate prevention)
        for (index, style) in newStyles.enumerated() {
            if style.associatedAppBundleIDs.contains(bundleID) {
                newStyles[index].associatedAppBundleIDs.removeAll { $0 == bundleID }
                if index != targetIndex {
                    movedFromStyle = style
                }
            }
        }
        
        // Add to target style if not already there
        if !newStyles[targetIndex].associatedAppBundleIDs.contains(bundleID) {
            newStyles[targetIndex].associatedAppBundleIDs.append(bundleID)
        }
        
        styles = newStyles
        
        if let fromStyle = movedFromStyle {
            Logger.styles.info("Moved '\(bundleID)' from '\(fromStyle.name)' to '\(targetStyle.name)'")
        } else {
            Logger.styles.info("Added '\(bundleID)' to '\(targetStyle.name)'")
        }
    }
    
    /// Reorders styles by moving items at the specified indices to the new position.
    /// Updates default status based on new order (first style becomes default).
    /// - Parameters:
    ///   - indices: The indices of styles to move.
    ///   - newOffset: The position to move the styles to.
    public func reorderStyles(from indices: IndexSet, to newOffset: Int) {
        guard !indices.isEmpty else { return }
        guard newOffset >= 0 && newOffset <= styles.count else { return }
        
        var newStyles = styles
        let movedStyles = indices.compactMap { index -> Style? in
            guard index < newStyles.count else { return nil }
            return newStyles[index]
        }
        
        // Remove in reverse order to maintain correct indices
        for index in indices.sorted(by: >) {
            guard index < newStyles.count else { continue }
            newStyles.remove(at: index)
        }
        
        // Calculate insertion position after removals
        var adjustedOffset = newOffset
        for index in indices {
            if index < newOffset {
                adjustedOffset -= 1
            }
        }
        adjustedOffset = max(0, min(adjustedOffset, newStyles.count))
        
        // Insert moved styles
        newStyles.insert(contentsOf: movedStyles, at: adjustedOffset)
        
        styles = newStyles
        syncDefaultFlags()
        
        let styleNames = styles.map { $0.name }.joined(separator: ", ")
        Logger.styles.info("Reordered styles, new order: \(styleNames)")
    }
    
    // MARK: - Public Helpers
    
    /// Returns the default style (first in the list).
    public func defaultStyle() -> Style {
        guard let first = styles.first else {
            // Fallback: return Casual if no styles exist
            return Style.casual
        }
        return first
    }
    
    /// Returns the style with the given ID, or nil if not found.
    /// - Parameter id: The style ID to look up.
    public func style(withID id: UUID) -> Style? {
        return styles.first { $0.id == id }
    }
    
    /// Returns all bundle IDs assigned to the given style.
    /// - Parameter style: The style to query.
    public func assignedApps(for style: Style) -> [String] {
        guard let foundStyle = styles.first(where: { $0.id == style.id }) else {
            return []
        }
        return foundStyle.associatedAppBundleIDs
    }
    
    /// Removes an app assignment from all styles.
    /// - Parameter bundleID: The bundle identifier to remove.
    public func removeAppAssignment(bundleID: String) {
        var newStyles = styles
        var wasAssigned = false
        
        for (index, style) in newStyles.enumerated() {
            if style.associatedAppBundleIDs.contains(bundleID) {
                newStyles[index].associatedAppBundleIDs.removeAll { $0 == bundleID }
                wasAssigned = true
                Logger.styles.info("Removed '\(bundleID)' from '\(style.name)'")
            }
        }
        
        if wasAssigned {
            styles = newStyles
        }
    }
    
    /// Updates a style in place. Used for modifying non-built-in properties.
    /// - Parameter style: The updated style.
    public func updateStyle(_ style: Style) {
        guard let index = styles.firstIndex(where: { $0.id == style.id }) else {
            Logger.styles.warning("Attempted to update non-existent style: \(style.name)")
            return
        }
        
        var newStyles = styles
        newStyles[index] = style
        styles = newStyles
        
        Logger.styles.info("Updated style: \(style.name)")
    }
    
    /// Resets a built-in style to its default state.
    /// For built-in styles, this clears all custom app assignments.
    /// - Parameter style: The style to reset.
    public func resetStyleToDefaults(_ style: Style) async {
        guard style.isBuiltIn else { return }
        
        // Remove all app assignments for this style
        for bundleID in style.associatedAppBundleIDs {
            await removeAppAssignment(bundleID: bundleID)
        }
        
        Logger.styles.info("Reset style to defaults: \(style.name)")
    }
    
    // MARK: - Private Methods
    
    private func initializeBuiltInStyles() {
        styles = Style.builtIn
        Logger.styles.info("Initialized built-in styles on first launch")
    }
    
    private func ensureBuiltInStylesExist() {
        var needsUpdate = false
        var currentStyles = styles
        var existingIDs = Set(currentStyles.map(\.id))
        
        // Add any missing built-in styles
        for builtIn in Style.builtIn {
            if !existingIDs.contains(builtIn.id) {
                currentStyles.append(builtIn)
                existingIDs.insert(builtIn.id)
                needsUpdate = true
                Logger.styles.info("Added missing built-in style: \(builtIn.name)")
            }
        }
        
        // Ensure built-in styles have correct immutable properties
        for (index, style) in currentStyles.enumerated() {
            if style.isBuiltIn {
                let correctBuiltIn = Style.builtIn.first { $0.id == style.id }
                if let correct = correctBuiltIn {
                    // Only update if immutable properties changed
                    if style.name != correct.name || 
                       style.staticRules != correct.staticRules {
                        var updated = style
                        // Preserve mutable properties (isDefault, associatedAppBundleIDs)
                        // Update immutable properties
                        updated = Style(
                            id: correct.id,
                            name: correct.name,
                            isBuiltIn: true,
                            isDefault: style.isDefault,
                            staticRules: correct.staticRules,
                            dynamicPrompt: correct.dynamicPrompt,
                            associatedAppBundleIDs: style.associatedAppBundleIDs
                        )
                        currentStyles[index] = updated
                        needsUpdate = true
                        Logger.styles.info("Restored built-in style properties: \(correct.name)")
                    }
                }
            }
        }
        
        if needsUpdate {
            styles = currentStyles
        }
    }
    
    private func syncDefaultFlags() {
        var newStyles = styles
        for index in newStyles.indices {
            let shouldBeDefault = index == 0
            if newStyles[index].isDefault != shouldBeDefault {
                newStyles[index].isDefault = shouldBeDefault
            }
        }
        // Only assign if actually changed to avoid triggering didSet unnecessarily
        if newStyles != styles {
            styles = newStyles
        }
    }
    
    private func updateStorageFromStyles() {
        var styleDict: [UUID: Style] = [:]
        var styleIDs: [UUID] = []
        var appAssignments: [String: UUID] = [:]
        
        for style in styles {
            styleDict[style.id] = style
            styleIDs.append(style.id)
            
            for bundleID in style.associatedAppBundleIDs {
                appAssignments[bundleID] = style.id
            }
        }
        
        storage = StyleRegistryStorage(
            version: StyleRegistryStorage.currentVersion,
            styleIDs: styleIDs,
            appAssignments: appAssignments,
            styles: styleDict
        )
    }
    
    private func persist() {
        do {
            let data = try JSONEncoder().encode(storage)
            userDefaults.set(data, forKey: Self.userDefaultsKey)
            Logger.styles.debug("Persisted style registry")
        } catch {
            Logger.styles.error("Failed to persist style registry: \(error.localizedDescription)")
        }
    }
    
    private static func loadStorage(from userDefaults: UserDefaults) -> StyleRegistryStorage? {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else {
            return nil
        }
        
        do {
            let storage = try JSONDecoder().decode(StyleRegistryStorage.self, from: data)
            Logger.styles.debug("Loaded style registry from storage")
            return storage
        } catch {
            Logger.styles.error("Failed to load style registry: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func orderedStyles(from storage: StyleRegistryStorage) -> [Style] {
        var result: [Style] = []
        
        // First, add styles in the persisted order
        for styleID in storage.styleIDs {
            if let style = storage.styles[styleID] {
                result.append(style)
            }
        }
        
        // Then add any styles not in the order list (recovery)
        let orderedIDs = Set(storage.styleIDs)
        for (id, style) in storage.styles {
            if !orderedIDs.contains(id) {
                result.append(style)
            }
        }
        
        return result
    }
}

// MARK: - Platform-Specific Protocol Extension

#if os(macOS)

import AppKit

public protocol FrontmostAppDetecting: Sendable {
    func currentFrontmostAppBundleID() -> String?
}

extension StyleRegistry {
    /// Returns the style for the current frontmost application.
    /// Falls back to the default style if frontmost app cannot be determined
    /// or if no style is assigned to the frontmost app.
    ///
    /// - Note: Requires Accessibility permission for NSWorkspace notifications.
    public func styleForFrontmostApp(detecting detector: FrontmostAppDetecting) -> Style {
        guard let bundleID = detector.currentFrontmostAppBundleID() else {
            return defaultStyle()
        }
        return style(forBundleID: bundleID)
    }
}

/// Default implementation using NSWorkspace for frontmost app detection.
public struct NSWorkspaceAppDetector: FrontmostAppDetecting {
    public init() {}
    
    public func currentFrontmostAppBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

#elseif os(iOS)

extension StyleRegistry {
    /// Returns the default style.
    /// On iOS, there's no frontmost app detection available.
    public func defaultStyleForiOS() -> Style {
        return defaultStyle()
    }
}

#endif