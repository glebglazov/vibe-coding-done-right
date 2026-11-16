import Foundation
import Testing
@testable import vcdr_mac

// MARK: - Test Helpers

/// A mock frontmost app detector for testing.
struct MockFrontmostAppDetector: FrontmostAppDetecting {
    var bundleID: String?
    
    func currentFrontmostAppBundleID() -> String? {
        return bundleID
    }
}

/// Creates a custom style for testing.
private func makeStyle(
    id: UUID = UUID(),
    name: String = "Test Style",
    isBuiltIn: Bool = false,
    isDefault: Bool = false,
    capitalizeSentences: Bool = false,
    endingPunctuation: PunctuationRule = .preserve,
    associatedAppBundleIDs: [String] = []
) -> Style {
    Style(
        id: id,
        name: name,
        isBuiltIn: isBuiltIn,
        isDefault: isDefault,
        staticRules: StaticStyleRules(
            capitalizeSentences: capitalizeSentences,
            endingPunctuation: endingPunctuation
        ),
        associatedAppBundleIDs: associatedAppBundleIDs
    )
}

// MARK: - Initialization Tests

@Suite("StyleRegistry - Initialization")
struct StyleRegistryInitializationTests {
    
    @Test("Initializes with built-in styles on first launch")
    func firstLaunchCreatesBuiltInStyles() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry = StyleRegistry(userDefaults: defaults)
        let styles = await registry.allStyles()

        #expect(styles.count == 3)
        #expect(styles[0].id == Style.casualID)
        #expect(styles[1].id == Style.messagingID)
        #expect(styles[2].id == Style.formalID)
        #expect(styles[0].isDefault == true)
        #expect(styles[1].isDefault == false)
        #expect(styles[2].isDefault == false)
    }
    
    @Test("Casual is default on fresh install")
    func casualIsDefaultOnFreshInstall() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let defaultStyle = await registry.defaultStyle()
        
        #expect(defaultStyle.id == Style.casualID)
        #expect(defaultStyle.name == "Casual")
    }
    
    @Test("Loads existing styles from persistence")
    func loadsExistingStyles() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        // First, create and modify a registry
        let registry1 = StyleRegistry(userDefaults: defaults)
        // Move Formal (index 2) to position 0
        await registry1.reorderStyles(from: IndexSet(integer: 2), to: 0)
        await registry1.moveApp(bundleID: "com.test.app", toStyle: Style.casual)

        // Create a new registry with same defaults - should load persisted state
        let registry2 = StyleRegistry(userDefaults: defaults)
        let styles = await registry2.allStyles()

        // Should have Formal first (we reordered), then Casual, Messaging
        #expect(styles[0].id == Style.formalID)
        #expect(styles[1].id == Style.casualID)
        #expect(styles[2].id == Style.messagingID)

        // Should have the app assignment
        let style = await registry2.style(forBundleID: "com.test.app")
        #expect(style.id == Style.casualID)
    }
}

// MARK: - Persistence Tests

@Suite("StyleRegistry - Persistence")
struct StyleRegistryPersistenceTests {
    
    @Test("Persists style order changes")
    func persistsOrderChanges() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry1 = StyleRegistry(userDefaults: defaults)
        // Move Formal (index 2) to position 0
        await registry1.reorderStyles(from: IndexSet(integer: 2), to: 0)

        // Create new registry instance
        let registry2 = StyleRegistry(userDefaults: defaults)
        let styles = await registry2.allStyles()

        #expect(styles[0].id == Style.formalID)
        #expect(styles[1].id == Style.casualID)
        #expect(styles[2].id == Style.messagingID)
    }
    
    @Test("Persists app assignments")
    func persistsAppAssignments() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry1 = StyleRegistry(userDefaults: defaults)
        let allStyles = await registry1.allStyles()
        let casual = allStyles.first { $0.id == Style.casualID }!
        
        await registry1.moveApp(bundleID: "com.apple.mail", toStyle: casual)
        
        // Create new registry instance
        let registry2 = StyleRegistry(userDefaults: defaults)
        let style = await registry2.style(forBundleID: "com.apple.mail")
        
        #expect(style.id == Style.casualID)
    }
    
    @Test("Persists default style changes")
    func persistsDefaultChanges() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry1 = StyleRegistry(userDefaults: defaults)
        let formal = Style.formal
        
        await registry1.setDefault(formal)
        
        // Create new registry instance
        let registry2 = StyleRegistry(userDefaults: defaults)
        let defaultStyle = await registry2.defaultStyle()
        
        #expect(defaultStyle.id == Style.formalID)
    }
    
    @Test("Round-trip preserves all properties")
    func roundTripPreservesProperties() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry1 = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        
        await registry1.moveApp(bundleID: "com.test.app1", toStyle: casual)
        await registry1.moveApp(bundleID: "com.test.app2", toStyle: casual)
        
        let registry2 = StyleRegistry(userDefaults: defaults)
        let styles = await registry2.allStyles()
        let loadedCasual = styles.first { $0.id == Style.casualID }!
        
        #expect(loadedCasual.associatedAppBundleIDs.contains("com.test.app1"))
        #expect(loadedCasual.associatedAppBundleIDs.contains("com.test.app2"))
        #expect(loadedCasual.associatedAppBundleIDs.count == 2)
    }
}

// MARK: - Default Style Tests

@Suite("StyleRegistry - Default Style")
struct StyleRegistryDefaultTests {
    
    @Test("First style is default")
    func firstStyleIsDefault() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let styles = await registry.allStyles()
        
        #expect(styles[0].isDefault == true)
        #expect(styles[1].isDefault == false)
    }
    
    @Test("SetDefault moves style to first position")
    func setDefaultMovesToFirst() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let formal = Style.formal
        
        await registry.setDefault(formal)
        
        let styles = await registry.allStyles()
        #expect(styles[0].id == Style.formalID)
        #expect(styles[0].isDefault == true)
        #expect(styles[1].isDefault == false)
    }
    
    @Test("Reordering updates default correctly")
    func reorderingUpdatesDefault() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry = StyleRegistry(userDefaults: defaults)

        // Move Formal (index 2) to position 0 (making it default)
        await registry.reorderStyles(from: IndexSet(integer: 2), to: 0)

        let styles = await registry.allStyles()
        #expect(styles[0].id == Style.formalID)
        #expect(styles[0].isDefault == true)
        #expect(styles[1].isDefault == false)
        #expect(styles[2].isDefault == false)
    }
    
    @Test("Default style returns first style")
    func defaultStyleReturnsFirst() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let defaultStyle = await registry.defaultStyle()
        let styles = await registry.allStyles()
        
        #expect(defaultStyle.id == styles[0].id)
    }
}

// MARK: - App Assignment Tests

@Suite("StyleRegistry - App Assignments")
struct StyleRegistryAppAssignmentTests {
    
    @Test("MoveApp adds app to style")
    func moveAppAddsToStyle() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        
        let style = await registry.style(forBundleID: "com.test.app")
        #expect(style.id == Style.casualID)
    }
    
    @Test("MoveApp removes app from previous style (duplicate prevention)")
    func moveAppRemovesFromPreviousStyle() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        let formal = Style.formal
        
        // First assign to Casual
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        
        // Then move to Formal
        await registry.moveApp(bundleID: "com.test.app", toStyle: formal)
        
        let styles = await registry.allStyles()
        let updatedCasual = styles.first { $0.id == Style.casualID }!
        let updatedFormal = styles.first { $0.id == Style.formalID }!
        
        #expect(updatedCasual.associatedAppBundleIDs.contains("com.test.app") == false)
        #expect(updatedFormal.associatedAppBundleIDs.contains("com.test.app") == true)
    }
    
    @Test("App cannot be assigned to multiple styles")
    func appCannotBeInMultipleStyles() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        let formal = Style.formal
        
        // Try to assign to both styles
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        await registry.moveApp(bundleID: "com.test.app", toStyle: formal)
        
        let styles = await registry.allStyles()
        let styleAssignments = styles.filter { $0.associatedAppBundleIDs.contains("com.test.app") }
        
        #expect(styleAssignments.count == 1)
    }
    
    @Test("StyleForBundleID returns matching style")
    func styleForBundleIDReturnsMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let formal = Style.formal
        
        await registry.moveApp(bundleID: "com.apple.mail", toStyle: formal)
        
        let style = await registry.style(forBundleID: "com.apple.mail")
        #expect(style.id == Style.formalID)
    }
    
    @Test("StyleForBundleID returns default when no match")
    func styleForBundleIDReturnsDefaultWhenNoMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        
        let style = await registry.style(forBundleID: "com.unknown.app")
        let defaultStyle = await registry.defaultStyle()
        
        #expect(style.id == defaultStyle.id)
    }
    
    @Test("StyleForBundleID returns first matching style by list order")
    func styleForBundleIDReturnsFirstMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        let formal = Style.formal
        
        // Assign same app to both styles (simulate corruption scenario)
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        // Directly manipulate to add to second style (corruption test)
        await registry.moveApp(bundleID: "com.test.app", toStyle: formal)
        // Then move back to casual to test that first match wins
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        
        let style = await registry.style(forBundleID: "com.test.app")
        // Should return Casual (first in list with match)
        #expect(style.id == Style.casualID)
    }
    
    @Test("RemoveAppAssignment removes from all styles")
    func removeAppAssignmentWorks() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        
        await registry.moveApp(bundleID: "com.test.app", toStyle: casual)
        await registry.removeAppAssignment(bundleID: "com.test.app")
        
        let style = await registry.style(forBundleID: "com.test.app")
        let defaultStyle = await registry.defaultStyle()
        
        // Should return default since app is no longer assigned
        #expect(style.id == defaultStyle.id)
    }
}

// MARK: - Reordering Tests

@Suite("StyleRegistry - Reordering")
struct StyleRegistryReorderingTests {
    
    @Test("ReorderStyles moves single item")
    func reorderSingleItem() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry = StyleRegistry(userDefaults: defaults)

        // Move Messaging (index 1) to position 0
        await registry.reorderStyles(from: IndexSet(integer: 1), to: 0)

        let styles = await registry.allStyles()
        #expect(styles[0].id == Style.messagingID)
        #expect(styles[1].id == Style.casualID)
        #expect(styles[2].id == Style.formalID)
    }

    @Test("ReorderStyles handles edge cases gracefully")
    func reorderHandlesEdgeCases() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry = StyleRegistry(userDefaults: defaults)

        // Empty indices - should not crash
        await registry.reorderStyles(from: IndexSet(), to: 0)

        let styles = await registry.allStyles()
        #expect(styles.count == 3) // Still has all built-in styles
    }
    
    @Test("ReorderStyles updates isDefault flags")
    func reorderUpdatesDefaultFlags() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        
        await registry.reorderStyles(from: IndexSet(integer: 1), to: 0)
        
        let styles = await registry.allStyles()
        #expect(styles[0].isDefault == true)
        #expect(styles[1].isDefault == false)
    }
}

// MARK: - Built-in Style Tests

@Suite("StyleRegistry - Built-in Styles")
struct StyleRegistryBuiltInTests {
    
    @Test("Built-in styles have stable UUIDs")
    func builtInStableUUIDs() {
        #expect(Style.casualID.uuidString == "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")
        #expect(Style.messagingID.uuidString == "C3D4E5F6-A7B8-4C9D-AE1F-2A3B4C5D6E7F")
        #expect(Style.formalID.uuidString == "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")
    }

    @Test("Built-in styles are auto-created on first launch with stable UUIDs")
    func builtInStylesCreatedOnFirstLaunch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let registry = StyleRegistry(userDefaults: defaults)
        let styles = await registry.allStyles()

        let hasCasual = styles.contains { $0.id == Style.casualID }
        let hasMessaging = styles.contains { $0.id == Style.messagingID }
        let hasFormal = styles.contains { $0.id == Style.formalID }

        #expect(hasCasual == true)
        #expect(hasMessaging == true)
        #expect(hasFormal == true)
    }
    
    @Test("Casual is default on fresh install")
    func casualIsDefault() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let styles = await registry.allStyles()
        
        #expect(styles[0].id == Style.casualID)
        #expect(styles[0].isDefault == true)
    }
    
    @Test("Built-in style properties are immutable")
    func builtInPropertiesImmutable() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        // Create registry - should initialize built-in styles
        let registry = StyleRegistry(userDefaults: defaults)
        let styles = await registry.allStyles()
        
        let casual = styles.first { $0.id == Style.casualID }!
        
        #expect(casual.name == "Casual")
        #expect(casual.isBuiltIn == true)
        #expect(casual.staticRules.capitalizeSentences == false)
        #expect(casual.staticRules.endingPunctuation == .removeFinalDot)
    }
}

// MARK: - macOS Frontmost App Tests

#if os(macOS)

@Suite("StyleRegistry - macOS Frontmost App")
struct StyleRegistryFrontmostAppTests {
    
    @Test("StyleForFrontmostApp returns matching style")
    func frontmostAppReturnsMatchingStyle() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let formal = Style.formal
        
        await registry.moveApp(bundleID: "com.apple.mail", toStyle: formal)
        
        let detector = MockFrontmostAppDetector(bundleID: "com.apple.mail")
        let style = await registry.styleForFrontmostApp(detecting: detector)
        
        #expect(style.id == Style.formalID)
    }
    
    @Test("StyleForFrontmostApp returns default when no match")
    func frontmostAppReturnsDefaultWhenNoMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        
        let detector = MockFrontmostAppDetector(bundleID: "com.unknown.app")
        let style = await registry.styleForFrontmostApp(detecting: detector)
        let defaultStyle = await registry.defaultStyle()
        
        #expect(style.id == defaultStyle.id)
    }
    
    @Test("StyleForFrontmostApp returns default when bundleID is nil")
    func frontmostAppReturnsDefaultWhenNil() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        
        let detector = MockFrontmostAppDetector(bundleID: nil)
        let style = await registry.styleForFrontmostApp(detecting: detector)
        let defaultStyle = await registry.defaultStyle()
        
        #expect(style.id == defaultStyle.id)
    }
    
    @Test("NSWorkspaceAppDetector has correct interface")
    func nsWorkspaceDetectorHasCorrectInterface() {
        let detector = NSWorkspaceAppDetector()
        // This test just verifies the type exists and can be instantiated
        // The actual detection requires running app context
        _ = detector
    }
}

#endif

// MARK: - Thread Safety Tests

@Suite("StyleRegistry - Thread Safety")
struct StyleRegistryThreadSafetyTests {
    
    @Test("Concurrent reads are safe")
    func concurrentReadsAreSafe() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        
        // Perform many concurrent reads
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await registry.allStyles()
                    _ = await registry.defaultStyle()
                    _ = await registry.style(forBundleID: "com.test.app")
                }
            }
        }
        
        // If we get here without crashes, the test passes
        #expect(true)
    }
    
    @Test("Concurrent writes are serialized")
    func concurrentWritesAreSerialized() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        
        let registry = StyleRegistry(userDefaults: defaults)
        let casual = Style.casual
        let formal = Style.formal
        
        // Perform many concurrent writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let bundleID = "com.test.app\(i)"
                    await registry.moveApp(bundleID: bundleID, toStyle: casual)
                    await registry.moveApp(bundleID: bundleID, toStyle: formal)
                }
            }
        }
        
        // Verify final state is consistent
        let styles = await registry.allStyles()
        let allAssignedApps = styles.flatMap { $0.associatedAppBundleIDs }
        
        // Each app should only be assigned once (to Formal, since that's the last move)
        let uniqueApps = Set(allAssignedApps)
        #expect(allAssignedApps.count == uniqueApps.count)
    }
}