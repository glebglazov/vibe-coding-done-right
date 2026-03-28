import SwiftUI

@main
struct VCDRiOSApp: App {
    @State private var coordinator = RecordingFlowCoordinator()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        WindowGroup {
            RecordingView(coordinator: coordinator)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    coordinator.cleanupStaleResults()
                    // coordinator.setupCommandListener() — disabled: no background recording commands
                    await coordinator.initializeModel()
                }
                .onOpenURL { url in
                    if url.scheme == "vcdr-ios", url.host == "record" {
                        // Set recording state synchronously so the first rendered frame
                        // shows "LISTENING" — eliminates the flash of the previous state.
                        coordinator.prepareForDeepLinkRecording()
                        Task { await coordinator.handleRecordDeepLink() }
                    } else if url.host == "connect" {
                        // QR pairing: vcdr://connect?host=...&key=...
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let host = components?.queryItems?.first(where: { $0.name == "host" })?.value
                        let key = components?.queryItems?.first(where: { $0.name == "key" })?.value
                        if let host, let key {
                            CompanionSettings.configureFromDeepLink(host: host, apiKey: key)
                        }
                    }
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

