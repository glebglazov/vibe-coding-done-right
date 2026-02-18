import SwiftUI

@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
                .task {
                    await dependencies.initialize()
                }
        } label: {
            Image(systemName: dependencies.coordinator.menuBarIcon)
        }

        Window("VCDR Settings", id: "settings") {
            SettingsView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 450, height: 350)
    }
}

