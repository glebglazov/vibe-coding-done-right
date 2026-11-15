import Foundation

/// How long each surface keeps a Discard on screen.
nonisolated enum DiscardTiming {
    /// The keyboard's DISCARDED pill, before START comes back.
    static let keyboardFlash: TimeInterval = 1
    /// The app's note that says where the discarded run went.
    static let appNote: TimeInterval = 3
}
