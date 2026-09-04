import Foundation

/// The build the app is running, read from its bundle. Both products name the
/// build in their version row, and a launch compares itself against the build
/// that ran last — one reading serves all of them, so the two spellings of a
/// version cannot drift apart from each other or from the bundle.
enum AppVersion {
    /// Stands in for a key the bundle does not carry: a named absence stays
    /// readable in a version row and in a stored comparison key, an empty
    /// string does not.
    private static let unknownComponent = "unknown"

    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? unknownComponent
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? unknownComponent
    }

    /// How a version row names the build.
    static var label: String { "\(marketingVersion) (\(buildNumber))" }
}
