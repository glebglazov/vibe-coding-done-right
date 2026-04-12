import Foundation

/// Cursor context captures the text surrounding the insertion point.
/// Used for context-aware formatting decisions.
public struct CursorContext: Codable, Equatable, Sendable {
    /// Text before the cursor (up to 200 characters).
    /// `nil` if context could not be captured (AX unavailable, terminals, password fields).
    public let beforeText: String?

    /// Text after the cursor (up to 200 characters).
    /// `nil` if context could not be captured.
    public let afterText: String?

    /// Bundle ID of the app where context was captured.
    /// Used downstream to check for staleness (user switched apps during recording).
    public let sourceBundleID: String?

    public init(beforeText: String?, afterText: String?, sourceBundleID: String?) {
        self.beforeText = beforeText
        self.afterText = afterText
        self.sourceBundleID = sourceBundleID
    }
}
