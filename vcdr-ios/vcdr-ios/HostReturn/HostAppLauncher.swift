import Foundation
import OSLog

/// Brings an installed app to the front by its bundle ID through the private
/// `LSApplicationWorkspace`. lsd then asks SpringBoard to activate the app
/// with no URL, so the app resumes on the screen it was on. A URL would be a
/// navigation, and an app like Muxify goes to its home screen on one.
@MainActor
enum HostAppLauncher {
    // MARK: - Constants

    private static let workspaceClassName = "LSApplicationWorkspace"
    private static let defaultWorkspaceSelector = NSSelectorFromString("defaultWorkspace")
    private static let openSelector = NSSelectorFromString("openApplicationWithBundleID:")

    static func open(_ host: HostBundleID) -> Bool {
        guard let workspaceClass = NSClassFromString(workspaceClassName) as? NSObject.Type,
              workspaceClass.responds(to: defaultWorkspaceSelector),
              let workspace = workspaceClass.perform(defaultWorkspaceSelector)?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: openSelector)
        else {
            Logger.app.notice("Host Return: \(workspaceClassName) open is missing")
            return false
        }
        typealias OpenFunction = @convention(c) (NSObject, Selector, NSString) -> Bool
        let function = unsafeBitCast(workspace.method(for: openSelector), to: OpenFunction.self)
        return function(workspace, openSelector, host.rawValue as NSString)
    }
}
