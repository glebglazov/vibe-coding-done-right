import Foundation

/// Manages persistence of custom modes
class CustomModesStorage {
    static let shared = CustomModesStorage()

    private let storageKey = "com.vcdr.customModes"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = .prettyPrinted
    }

    /// Load all custom modes from storage
    func loadCustomModes() -> [CustomMode] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            print("📦 No custom modes found in storage")
            return []
        }

        do {
            let modes = try decoder.decode([CustomMode].self, from: data)
            print("📦 Loaded \(modes.count) custom mode(s) from storage")
            return modes
        } catch {
            print("❌ Failed to decode custom modes: \(error)")
            return []
        }
    }

    /// Save custom modes to storage
    func saveCustomModes(_ modes: [CustomMode]) {
        do {
            let data = try encoder.encode(modes)
            UserDefaults.standard.set(data, forKey: storageKey)
            print("💾 Saved \(modes.count) custom mode(s) to storage")
        } catch {
            print("❌ Failed to encode custom modes: \(error)")
        }
    }

    /// Add a new custom mode
    func addCustomMode(_ mode: CustomMode) {
        var modes = loadCustomModes()
        modes.append(mode)
        saveCustomModes(modes)
    }

    /// Update an existing custom mode
    func updateCustomMode(_ mode: CustomMode) {
        var modes = loadCustomModes()
        if let index = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[index] = mode
            saveCustomModes(modes)
            print("✏️ Updated custom mode: \(mode.name)")
        } else {
            print("⚠️ Custom mode not found for update: \(mode.id)")
        }
    }

    /// Delete a custom mode
    func deleteCustomMode(_ mode: CustomMode) {
        var modes = loadCustomModes()
        modes.removeAll { $0.id == mode.id }
        saveCustomModes(modes)
        print("🗑️ Deleted custom mode: \(mode.name)")
    }

    /// Delete a custom mode by ID
    func deleteCustomMode(withId id: UUID) {
        var modes = loadCustomModes()
        modes.removeAll { $0.id == id }
        saveCustomModes(modes)
        print("🗑️ Deleted custom mode with ID: \(id)")
    }
}
