import SwiftUI

// MARK: - Navigation Value

/// Navigation value for style detail views.
/// Distinguishes style UUIDs from mode UUIDs in NavigationStack.
struct StyleNavID: Hashable {
    let id: UUID
}

// MARK: - Styles List View

/// List of styles with NavigationLink rows (chevrons).
/// Lives inside a NavigationStack owned by MainWindowView.
struct StylesListView: View {
    let styleRegistry: StyleRegistry
    @Binding var path: NavigationPath

    @State private var styles: [Style] = []

    var body: some View {
        List {
            ForEach(styles) { style in
                NavigationLink(value: StyleNavID(id: style.id)) {
                    StyleRowView(
                        style: style,
                        isDefault: style.isDefault
                    )
                }
                .contextMenu {
                    if style.isBuiltIn {
                        Button("Reset to Defaults") {
                            resetToDefaults(style)
                        }
                    }
                }
            }
            .onMove { source, destination in
                moveStyles(from: source, to: destination)
            }
        }
        .navigationTitle("Styles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Placeholder for future "Add Custom Style" feature
                Button(action: {}) {
                    Image(systemName: "plus")
                }
                .help("Add custom style (coming soon)")
                .disabled(true)
            }
        }
        .task {
            await loadStyles()
        }
    }

    // MARK: - Actions

    private func loadStyles() async {
        styles = await styleRegistry.allStyles()
    }

    private func moveStyles(from source: IndexSet, to destination: Int) {
        Task {
            await styleRegistry.reorderStyles(from: source, to: destination)
            await loadStyles()
        }
    }

    private func resetToDefaults(_ style: Style) {
        Task {
            await styleRegistry.resetStyleToDefaults(style)
            await loadStyles()
        }
    }
}

// MARK: - Style Row

private struct StyleRowView: View {
    let style: Style
    let isDefault: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(style.name)

                    if isDefault {
                        DefaultBadge()
                    }
                }

                Text("\(style.associatedAppBundleIDs.count) apps assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if style.isBuiltIn {
                Text("Built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Style Detail Container

/// Async-loading container for StyleDetailView.
/// Handles fetching fresh style data when navigating to a detail view.
struct StyleDetailContainer: View {
    let styleID: UUID
    let styleRegistry: StyleRegistry

    @State private var style: Style?
    @State private var allStyles: [Style] = []

    var body: some View {
        Group {
            if let style {
                StyleDetailView(
                    style: style,
                    styleRegistry: styleRegistry,
                    allStyles: allStyles
                )
            } else {
                ProgressView("Loading style...")
            }
        }
        .task {
            await loadData()
        }
    }

    private func loadData() async {
        allStyles = await styleRegistry.allStyles()
        style = allStyles.first { $0.id == styleID }
    }
}

// MARK: - Style Detail View

struct StyleDetailView: View {
    let style: Style
    let styleRegistry: StyleRegistry
    let allStyles: [Style]

    @State private var assignedApps: [String] = []
    @State private var showAppPicker = false

    /// Bundle IDs already assigned to other styles
    private var assignedToOtherStyles: Set<String> {
        Set(allStyles
            .filter { $0.id != style.id }
            .flatMap { $0.associatedAppBundleIDs }
        )
    }

    var body: some View {
        Form {
            // Header section with reset button for built-in styles
            if style.isBuiltIn {
                Section {
                    HStack {
                        Label("Built-in style — can be reordered and assigned apps.", systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Defaults") {
                            resetToDefaults()
                        }
                        .font(.caption)
                    }
                }
            }

            // Style info
            Section {
                LabeledContent("Name", value: style.name)

                if style.isDefault {
                    LabeledContent("Default", value: "Used for unassigned apps")
                }
            }

            // App assignments
            Section {
                if style.isDefault {
                    // Default style: show info that it applies to all unassigned apps
                    Label {
                        Text("The default style automatically applies to all apps that aren't assigned to a specific style.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    // Non-default styles: show app assignments
                    if assignedApps.isEmpty {
                        ContentUnavailableView {
                            Label("No Apps Assigned", systemImage: "app.dashed")
                        } description: {
                            Text("Add apps to use the \"\(style.name)\" style.")
                        }
                    } else {
                        ForEach(assignedApps, id: \.self) { bundleID in
                            AppRow(bundleID: bundleID)
                        }
                        .onDelete { indexSet in
                            removeApps(at: indexSet)
                        }
                    }
                }
            } header: {
                if !style.isDefault {
                    HStack {
                        Text("Assigned Applications")
                        Spacer()
                        Text("\(assignedApps.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } footer: {
                if !style.isDefault {
                    Text("These apps will use the \"\(style.name)\" style when active.")
                        .font(.caption)
                }
            }

            // Add app button (only for non-default styles)
            if !style.isDefault {
                Section {
                    Button {
                        showAppPicker = true
                    } label: {
                        Label("Add App", systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(style.name)
        .task {
            await loadAssignedApps()
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerView(
                styleRegistry: styleRegistry,
                currentStyle: style,
                allStyles: allStyles,
                onSelect: { bundleID in
                    addApp(bundleID: bundleID)
                }
            )
            .frame(minWidth: 500, minHeight: 400)
        }
    }

    // MARK: - Actions

    private func loadAssignedApps() async {
        assignedApps = await styleRegistry.assignedApps(for: style)
    }

    private func addApp(bundleID: String) {
        Task {
            await styleRegistry.moveApp(bundleID: bundleID, toStyle: style)
            await loadAssignedApps()
        }
    }

    private func removeApps(at indexSet: IndexSet) {
        Task {
            for index in indexSet {
                let bundleID = assignedApps[index]
                await styleRegistry.removeAppAssignment(bundleID: bundleID)
            }
            await loadAssignedApps()
        }
    }

    private func resetToDefaults() {
        Task {
            await styleRegistry.resetStyleToDefaults(style)
            await loadAssignedApps()
        }
    }
}

// MARK: - App Row

private struct AppRow: View {
    let bundleID: String

    @State private var appInfo: AppInfo?

    var body: some View {
        HStack(spacing: 12) {
            if let icon = appInfo?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }

            Text(appInfo?.displayName ?? bundleID)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 2)
        .task {
            appInfo = await AppInfoFetcher.info(for: bundleID)
        }
    }
}

// MARK: - Default Badge

private struct DefaultBadge: View {
    var body: some View {
        Text("Default")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

// MARK: - App Info Fetcher

private struct AppInfo: Sendable {
    let displayName: String
    let icon: NSImage?
}

private actor AppInfoFetcher {
    private static var cache: [String: AppInfo] = [:]

    static func info(for bundleID: String) async -> AppInfo {
        if let cached = cache[bundleID] {
            return cached
        }

        let info = await fetchInfo(for: bundleID)
        cache[bundleID] = info
        return info
    }

    private static func fetchInfo(for bundleID: String) async -> AppInfo {
        let workspace = NSWorkspace.shared

        // Try to find running app first
        if let runningApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            let name = runningApp.localizedName ?? bundleID
            let icon = runningApp.icon
            return AppInfo(displayName: name, icon: icon)
        }

        // Try to find the app on disk
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundleID
            let icon = workspace.icon(forFile: url.path)
            return AppInfo(displayName: name, icon: icon)
        }

        // Fallback to bundle ID
        return AppInfo(displayName: bundleID, icon: nil)
    }
}

// MARK: - Previews

#Preview("Styles List") {
    NavigationStack {
        StylesListView(
            styleRegistry: StyleRegistry(),
            path: .constant(NavigationPath())
        )
    }
    .frame(width: 400, height: 400)
}

#Preview("Style Detail") {
    NavigationStack {
        StyleDetailView(
            style: Style.casual,
            styleRegistry: StyleRegistry(),
            allStyles: Style.builtIn
        )
    }
    .frame(width: 500, height: 500)
}
