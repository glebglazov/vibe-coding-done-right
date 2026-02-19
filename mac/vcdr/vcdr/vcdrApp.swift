import SwiftUI

@main
struct vcdrApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(dependencies: dependencies)
        } label: {
            Image(systemName: dependencies.coordinator.menuBarIcon)
        }

        Window("VCDR", id: "main") {
            MainWindowView(dependencies: dependencies)
                .task {
                    await dependencies.initialize()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 650, height: 450)
    }
}
