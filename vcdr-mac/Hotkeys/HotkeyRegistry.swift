import Foundation

/// Boundary between the types that own a hotkey and the mechanism that claims key
/// combinations from the system.
///
/// `CarbonHotkeyRegistry` is production. Substituting a double is the only way a
/// test can drive a key press at all: the real mechanism registers with the window
/// server, and no test can press a key there.
@MainActor
protocol HotkeyRegistry: AnyObject {
    /// Claims `binding` for as long as the returned handle is held.
    ///
    /// `onPress` is called synchronously on the main thread, so an owner reacting
    /// to a key press does so with no scheduling latency in between.
    ///
    /// - Returns: the handle, or `nil` when the combination could not be claimed.
    func claim(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyClaim?
}
