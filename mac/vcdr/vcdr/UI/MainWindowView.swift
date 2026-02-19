import SwiftUI

struct MainWindowView: View {
    let dependencies: AppDependencies

    var body: some View {
        TabView {
            HomeTabView(dependencies: dependencies)
                .tabItem { Label("Home", systemImage: "house") }

            ModesTabView(settings: dependencies.settings)
                .tabItem { Label("Modes", systemImage: "list.bullet") }

            TranscriptionTabView(dependencies: dependencies)
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
