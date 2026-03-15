import Foundation

@MainActor
protocol ModeSwitcherCoordinatorDelegate: AnyObject {
    func modeSwitcherShouldShowContextual() -> Bool
    func modeSwitcherShouldDismissContextual() -> Bool
    func modeSwitcherDidShowContextual()
    func modeSwitcherDidHideContextual()
}
