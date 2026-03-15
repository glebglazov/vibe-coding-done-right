import SwiftUI

/// Navigation value for output destination detail views.
/// Distinguishes output destination UUIDs from mode UUIDs in NavigationStack.
struct OutputDestinationNavID: Hashable {
    let id: UUID
}

struct MainWindowView: View {
    let dependencies: AppDependencies

    enum Tab: String, CaseIterable, Hashable {
        case home
        case audio
        case modes
        case outputDestinations
        case transcription
        case history
        #if DEBUG
        case debug
        #endif

        var title: String {
            switch self {
            case .home: "Home"
            case .audio: "Audio"
            case .modes: "Modes"
            case .outputDestinations: "Output"
            case .transcription: "Transcription"
            case .history: "History"
            #if DEBUG
            case .debug: "Debug"
            #endif
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .audio: "speaker.wave.2"
            case .modes: "list.bullet"
            case .outputDestinations: "arrow.right.square"
            case .transcription: "waveform"
            case .history: "clock.arrow.circlepath"
            #if DEBUG
            case .debug: "ant"
            #endif
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
                        HomeTabView(
                            settings: dependencies.settings,
                            coordinator: dependencies.coordinator,
                            modeSwitcherCoordinator: dependencies.modeSwitcherCoordinator,
                            captureCoordinator: dependencies.captureCoordinator,
                            copyLatestCaptureHandler: dependencies.copyLatestCaptureHandler,
                            hasMicrophonePermission: dependencies.hasMicrophonePermission,
                            hasAccessibilityPermission: dependencies.hasAccessibilityPermission
                        )
                    case .audio:
                        AudioTabView(
                            audioDeviceMonitor: dependencies.audioDeviceMonitor,
                            inputLevelMonitor: dependencies.inputLevelMonitor,
                            settings: dependencies.settings,
                            hasMicrophonePermission: dependencies.hasMicrophonePermission
                        )
                    case .modes:
                        ModesListView(settings: dependencies.settings, path: $path)
                    case .outputDestinations:
                        OutputDestinationsListView(settings: dependencies.settings, path: $path)
                    case .transcription:
                        TranscriptionTabView(
                            settings: dependencies.settings,
                            isTranscriptionReady: dependencies.isTranscriptionReady,
                            initializationStatus: dependencies.initializationStatus
                        )
                    case .history:
                        HistoryTabView(
                            history: dependencies.transcriptionHistory,
                            settings: dependencies.settings,
                            onOpenConversation: { conversation in
                                dependencies.openConversationFromHistory(conversation)
                            }
                        )
                    #if DEBUG
                    case .debug:
                        DebugTabView(
                            coordinator: dependencies.coordinator,
                            audioRecorder: dependencies.audioRecorder,
                            isTranscriptionReady: dependencies.isTranscriptionReady
                        )
                    #endif
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
                            ),
                            outputDestinations: dependencies.settings.outputDestinations
                        )
                    }
                }
                .navigationDestination(for: OutputDestinationNavID.self) { navID in
                    if let index = dependencies.settings.outputDestinations.firstIndex(where: { $0.id == navID.id }) {
                        OutputDestinationDetailView(
                            destination: Binding(
                                get: { dependencies.settings.outputDestinations[index] },
                                set: { dependencies.settings.outputDestinations[index] = $0 }
                            )
                        )
                    }
                }
            }
        }
        .frame(minWidth: Self.windowMinWidth, minHeight: Self.windowMinHeight)
        .task {
            await dependencies.settings.refreshTemplateAvailability()
        }
        .onChange(of: selection) {
            // Reset push navigation when switching tabs
            path = NavigationPath()
        }
    }
}
