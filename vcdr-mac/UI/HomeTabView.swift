import SwiftUI
import AVFoundation

struct HomeTabView: View {
    // MARK: - Constants

    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Bindable var settings: AppSettings
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let hasMicrophonePermission: Bool
    let hasAccessibilityPermission: Bool
    let isInitialized: Bool
    @Bindable var diagnosticsUnlock: DiagnosticsUnlock

    @AppStorage(HistoryStoreFactory.syncEnabledDefaultsKey) private var syncHistoryViaICloud: Bool = true
    private var needsPermissionAttention: Bool {
        isInitialized && (!hasMicrophonePermission || !hasAccessibilityPermission)
    }

    var body: some View {
        Form {
            if needsPermissionAttention {
                Section {
                    if !hasMicrophonePermission {
                        LabeledContent {
                            Button("Grant Access") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            }
                            .controlSize(.small)
                        } label: {
                            Text("Microphone")
                            Text("Required to record your voice for transcription.")
                        }
                    }
                    if !hasAccessibilityPermission {
                        LabeledContent {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(Self.accessibilitySettingsURL)
                            }
                            .controlSize(.small)
                        } label: {
                            Text("Accessibility")
                            Text("Required to paste transcribed text into active apps.")
                        }
                    }
                } header: {
                    Label("Permissions Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Quick Actions") {
                HStack {
                    Spacer()
                    Button(action: { modeSwitcherCoordinator.showSwitcher() }) {
                        let mode = settings.activeMode
                        let dest = settings.outputDestination(for: mode.defaultOutputDestinationID)
                        Text(buildModeLabel(modeName: mode.name, parameterLabels: mode.defaultParameterLabels, destinationSymbol: dest.symbol))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }

            Section {
                Toggle("Sync history via iCloud", isOn: $syncHistoryViaICloud)
            } header: {
                Text("Sync")
            } footer: {
                Text("Share your transcription history with your iPhone via iCloud Drive. Requires an app restart to apply.")
            }

            Section("Shortcuts") {
                ShortcutRecorderRow(
                    label: "Toggle Recording",
                    hotkey: $settings.hotkeySettings.toggleRecordingHotkey
                )
                ShortcutRecorderRow(
                    label: "Mode Switcher",
                    hotkey: $settings.hotkeySettings.modeSwitcherHotkey
                )
                ShortcutRecorderRow(
                    label: "Cancel Capture",
                    hotkey: $settings.hotkeySettings.cancelRecordingHotkey
                )
                ShortcutRecorderRow(
                    label: "Copy Latest Capture",
                    hotkey: $settings.hotkeySettings.copyLatestCaptureHotkey
                )
            }

            if diagnosticsUnlock.isRevealed {
                diagnosticsSettingsSection
            }
            versionSection
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    // MARK: - Diagnostics Settings

    /// Sits beside the version row rather than in the Diagnostics tab: a switch
    /// that hid the way back to itself would be a trap.
    private var diagnosticsSettingsSection: some View {
        Section {
            Toggle("Show Diagnostics", isOn: $diagnosticsUnlock.isShown)
            Button("Forget Diagnostics") {
                diagnosticsUnlock.forget()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The switch only hides the Diagnostics tab — the app keeps recording its log either way. \"Forget Diagnostics\" also puts this section away until you click the version row ten times again.")
        }
    }

    // MARK: - Version

    /// The Diagnostics Unlock lives here: the row names the running build, and
    /// ten clicks on it reveal the Diagnostics tab in the sidebar.
    private var versionSection: some View {
        Section {
            Button {
                diagnosticsUnlock.registerTap()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Version") {
                        Text(Self.versionLabel)
                            .foregroundStyle(.secondary)
                    }
                    if let remaining = diagnosticsUnlock.tapsRemaining {
                        Text(remaining == 1 ? "1 more click" : "\(remaining) more clicks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let marketingVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(marketingVersion) (\(buildNumber))"
    }
}
