import Foundation

@MainActor
protocol ModeSwitcherCoordinatorDelegate: AnyObject {
    /// Whether audio recording is currently in progress (for recording dot display)
    var isRecordingActive: Bool { get }

    /// Called just before the standalone mode switcher panel is shown.
    /// The delegate should hide any underlying panels and suspend the cancel hotkey.
    func modeSwitcherWillShow()

    /// Called after the standalone mode switcher panel is hidden (by any path).
    /// The delegate should restore any underlying panels and resume the cancel hotkey.
    func modeSwitcherDidHide()
}
