import Foundation

/// A style defines how transcribed text should be formatted.
/// Styles are orthogonal to modes — they apply as a final transformation
/// step regardless of which mode processed the text.
public struct Style: Codable, Equatable, Identifiable, Sendable {
    /// Unique identifier for the style.
    public let id: UUID
    
    /// Display name for the style (e.g., "Casual", "Formal").
    public let name: String
    
    /// Whether this is a built-in style that cannot be deleted.
    /// Built-in styles have immutable core behavior.
    public let isBuiltIn: Bool
    
    /// Whether this is the default style (catch-all for unassigned apps).
    /// Only one style should be default at a time (typically first in list).
    public var isDefault: Bool
    
    /// Static text transformation rules applied to all outputs.
    public let staticRules: StaticStyleRules
    
    /// Optional dynamic prompt appended to AI mode system prompts.
    /// For v1, this is always nil/empty. Reserved for future LLM-based styles.
    public let dynamicPrompt: String?
    
    /// Bundle IDs of applications associated with this style (macOS only).
    /// When the frontmost app matches a bundle ID here, this style is selected.
    public var associatedAppBundleIDs: [String]
    
    /// Creates a new style.
    /// - Parameters:
    ///   - id: Unique identifier (use stable UUID for built-in styles)
    ///   - name: Display name
    ///   - isBuiltIn: Whether this is a built-in, immutable style
    ///   - isDefault: Whether this is the default/catch-all style
    ///   - staticRules: Static text transformation rules
    ///   - dynamicPrompt: Optional LLM prompt for dynamic styling (v2 feature)
    ///   - associatedAppBundleIDs: Associated application bundle IDs
    public init(
        id: UUID,
        name: String,
        isBuiltIn: Bool,
        isDefault: Bool,
        staticRules: StaticStyleRules,
        dynamicPrompt: String? = nil,
        associatedAppBundleIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isDefault = isDefault
        self.staticRules = staticRules
        self.dynamicPrompt = dynamicPrompt
        self.associatedAppBundleIDs = associatedAppBundleIDs
    }
}

// MARK: - Built-in Styles

extension Style {
    /// Stable UUID for the Casual built-in style.
    /// Do not change — used for persistence and migration.
    public static let casualID = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!

    /// Stable UUID for the Messaging built-in style.
    /// Do not change — used for persistence and migration.
    public static let messagingID = UUID(uuidString: "C3D4E5F6-A7B8-4C9D-AE1F-2A3B4C5D6E7F")!

    /// Stable UUID for the Formal built-in style.
    /// Do not change — used for persistence and migration.
    public static let formalID = UUID(uuidString: "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")!

    /// The Casual style: lowercase sentences, remove final period.
    /// Best for informal contexts like Terminal, Slack, or quick notes.
    public static let casual = Style(
        id: casualID,
        name: "Casual",
        isBuiltIn: true,
        isDefault: true,
        staticRules: .casual,
        dynamicPrompt: nil,
        associatedAppBundleIDs: []
    )

    /// The Messaging style: capitalize sentences, drop the final period.
    /// Best for chat and DM contexts like Messages, WhatsApp, or Telegram,
    /// where a trailing dot can read as cold or passive-aggressive.
    public static let messaging = Style(
        id: messagingID,
        name: "Messaging",
        isBuiltIn: true,
        isDefault: false,
        staticRules: .messaging,
        dynamicPrompt: nil,
        associatedAppBundleIDs: []
    )

    /// The Formal style: capitalize sentences, ensure ending punctuation.
    /// Best for professional contexts like Email, Documents, or Presentations.
    public static let formal = Style(
        id: formalID,
        name: "Formal",
        isBuiltIn: true,
        isDefault: false,
        staticRules: .formal,
        dynamicPrompt: nil,
        associatedAppBundleIDs: []
    )

    /// All built-in styles in their default order.
    /// The first style is the default.
    public static let builtIn: [Style] = [.casual, .messaging, .formal]
}
