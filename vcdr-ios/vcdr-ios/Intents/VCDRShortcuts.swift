import AppIntents

/// Puts Toggle Recording in Shortcuts and Spotlight with no setup, which is
/// also what an iPad hardware-keyboard shortcut binds to.
struct VCDRShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle recording in \(.applicationName)"],
            shortTitle: "Toggle Recording",
            systemImageName: "mic"
        )
    }
}
