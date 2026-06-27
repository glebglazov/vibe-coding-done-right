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
        case providers
        case styles
        case substitutions
        case outputDestinations
        case transcription
        case history
        case variables
        #if DEBUG
        case debug
        #endif

        var title: String {
            switch self {
            case .home: "Home"
            case .audio: "Audio"
            case .modes: "Modes"
            case .providers: "Providers"
            case .styles: "Styles"
            case .variables: "Variables"
            case .substitutions: "Substitutions"
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
            case .providers: "sparkles"
            case .styles: "paintbrush"
            case .variables: "key"
            case .substitutions: "arrow.left.arrow.right"
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
            List(selection: $selection) {
                Section {
                    ForEach([Tab.home, .audio, .modes, .providers, .styles, .substitutions, .outputDestinations, .transcription, .history], id: \.self) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                Section("Advanced") {
                    Label(Tab.variables.title, systemImage: Tab.variables.systemImage)
                        .tag(Tab.variables)
                    #if DEBUG
                    Label(Tab.debug.title, systemImage: Tab.debug.systemImage)
                        .tag(Tab.debug)
                    #endif
                }
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
                            session: dependencies.session,
                            modeSwitcherCoordinator: dependencies.modeSwitcherCoordinator,
                            copyLatestCaptureHandler: dependencies.copyLatestCaptureHandler,
                            hasMicrophonePermission: dependencies.hasMicrophonePermission,
                            hasAccessibilityPermission: dependencies.hasAccessibilityPermission,
                            isInitialized: dependencies.isInitialized
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
                    case .providers:
                        ProvidersListView(settings: dependencies.settings)
                    case .styles:
                        StylesListView(
                            styleRegistry: dependencies.styleRegistry,
                            path: $path
                        )
                    case .variables:
                        VariablesTabView(settings: dependencies.settings)
                    case .substitutions:
                        SubstitutionsTabView(store: dependencies.substitutionStore)
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
                            settings: dependencies.settings
                        )
                    #if DEBUG
                    case .debug:
                        DebugTabView(
                            session: dependencies.session,
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
                            settings: dependencies.settings,
                            outputDestinations: dependencies.settings.outputDestinations,
                            definedVariableNames: dependencies.settings.definedVariableNames
                        )
                    }
                }
                .navigationDestination(for: OutputDestinationNavID.self) { navID in
                    if let index = dependencies.settings.outputDestinations.firstIndex(where: { $0.id == navID.id }) {
                        OutputDestinationDetailView(
                            destination: Binding(
                                get: { dependencies.settings.outputDestinations[index] },
                                set: { dependencies.settings.outputDestinations[index] = $0 }
                            ),
                            definedVariableNames: dependencies.settings.definedVariableNames
                        )
                    }
                }
                .navigationDestination(for: StyleNavID.self) { navID in
                    StyleDetailContainer(
                        styleID: navID.id,
                        styleRegistry: dependencies.styleRegistry
                    )
                }
                .navigationDestination(for: AIProvider.self) { provider in
                    ProviderDetailView(
                        provider: provider,
                        apiKey: Binding(
                            get: { dependencies.settings.apiKey(for: provider) },
                            set: { dependencies.settings.setAPIKey($0, for: provider) }
                        )
                    )
                }
            }
        }
        .frame(minWidth: Self.windowMinWidth, minHeight: Self.windowMinHeight)
        .environment(\.hotkeySuppressionHandler) { suppressed in
            dependencies.setHotkeySuppression(suppressed)
        }
        .task {
            await dependencies.settings.refreshTemplateAvailability()
        }
        .onChange(of: selection) {
            // Reset push navigation when switching tabs
            path = NavigationPath()
        }
    }
}
