import SwiftUI

/// Encapsulates the "copied!" feedback pattern: sets a boolean true,
/// sleeps for a duration, then resets it to false.
enum CopiedFeedback {
    // MARK: - Constants

    static let duration: Duration = .seconds(1.5)

    /// Triggers copied feedback: sets the binding to true, waits, then resets.
    static func trigger(_ showCopied: Binding<Bool>) {
        showCopied.wrappedValue = true
        Task {
            try? await Task.sleep(for: duration)
            showCopied.wrappedValue = false
        }
    }
}
