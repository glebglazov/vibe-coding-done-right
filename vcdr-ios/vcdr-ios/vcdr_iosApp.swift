import SwiftUI

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .themeFromColorScheme()
                .task {
                    coordinator.cleanupStaleResults()
                    // coordinator.setupCommandListener() — disabled: no background recording commands
                    await coordinator.initializeModel()
                }
                .onOpenURL { url in
                    guard url.scheme == "vcdr-ios", url.host == "record" else { return }
                    Task { await coordinator.handleRecordDeepLink() }
                }
        }
    }
}

/// User-selectable appearance mode, stored via @AppStorage.
enum Appearance: String, CaseIterable {
    case dark
    case light
    case system

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }
}

// MARK: - Theme Resolver

/// Reads the effective color scheme and injects the matching Theme into the environment.
private struct ThemeResolverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.theme, Theme.current(for: colorScheme))
    }
}

extension View {
    func themeFromColorScheme() -> some View {
        modifier(ThemeResolverModifier())
    }
}
