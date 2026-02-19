import SwiftUI

struct MainWindowView: View {
    let dependencies: AppDependencies

    enum Tab: String, CaseIterable, Hashable {
        case home
        case modes
        case transcription

        var title: String {
            switch self {
            case .home: "Home"
            case .modes: "Modes"
            case .transcription: "Transcription"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .modes: "list.bullet"
            case .transcription: "waveform"
            }
        }
    }

    // MARK: - Constants
    private static let sidebarWidth: CGFloat = 180
    private static let windowMinWidth: CGFloat = 550
    private static let windowMinHeight: CGFloat = 400

    @State private var selection: Tab? = .home
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            List(Tab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch selection {
                    case .home:
                        HomeTabView(dependencies: dependencies)
                    case .modes:
                        ModesListView(settings: dependencies.settings)
                    case .transcription:
                        TranscriptionTabView(dependencies: dependencies)
                    case .none:
                        Text("Select a section")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationDestination(for: UUID.self) { modeID in
                    if let index = dependencies.settings.modes.firstIndex(where: { $0.id == modeID }) {
                        ModeDetailView(
                            mode: Binding(
                                get: { dependencies.settings.modes[index] },
                                set: { dependencies.settings.modes[index] = $0 }
                            )
                        )
                    }
                }
            }
        }
        .frame(minWidth: Self.windowMinWidth, minHeight: Self.windowMinHeight)
        .onChange(of: selection) {
            // Reset push navigation when switching tabs
            path = NavigationPath()
        }
    }
}
