import Foundation

/// Available text styles for formatting transcribed output.
/// Raw values used for persistence.
public enum TextStyle: String, Codable, CaseIterable, Sendable {
    case casual
    case messaging
    case formal

    public var displayName: String {
        switch self {
        case .casual: "Casual"
        case .messaging: "Messaging"
        case .formal: "Formal"
        }
    }

    public var example: String {
        switch self {
        case .casual: "hey just wanted to check in about the meeting tomorrow"
        case .messaging: "Hey just wanted to check in about tomorrow's meeting"
        case .formal: "I wanted to follow up regarding tomorrow's meeting."
        }
    }

    /// Returns the Style model associated with this text style.
    public var style: Style {
        switch self {
        case .casual: .casual
        case .messaging: .messaging
        case .formal: .formal
        }
    }

    /// Creates a TextStyle from a Style model.
    /// Defaults to casual if the style ID doesn't match known styles.
    public init(style: Style) {
        if style.id == Style.casualID {
            self = .casual
        } else if style.id == Style.messagingID {
            self = .messaging
        } else if style.id == Style.formalID {
            self = .formal
        } else {
            self = .casual
        }
    }
}

/// Reads and writes style settings from UserDefaults.
/// The settings view writes via @AppStorage; other code reads through these static properties.
public enum StyleSettings {
    public static let defaultStyleKey = "text_style_default"
    
    /// The default text style for new recording sessions.
    /// Defaults to .casual on fresh install.
    public static var defaultStyle: TextStyle {
        get {
            TextStyle(rawValue: UserDefaults.standard.string(forKey: defaultStyleKey) ?? "") ?? .casual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultStyleKey)
        }
    }
    
    /// The Style model for the default text style.
    public static var defaultStyleModel: Style {
        defaultStyle.style
    }
}