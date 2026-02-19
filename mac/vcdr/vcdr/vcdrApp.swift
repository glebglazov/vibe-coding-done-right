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

        Window("VCDR", id: "main") {
            MainWindowView(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 450)
    }
}
