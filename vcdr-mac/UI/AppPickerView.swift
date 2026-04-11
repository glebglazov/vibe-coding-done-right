import SwiftUI
import UniformTypeIdentifiers
import OSLog

/// Modal view for picking applications to assign to a style.
/// Shows running applications and provides a browse button for selecting any .app.
struct AppPickerView: View {
    let styleRegistry: StyleRegistry
    let currentStyle: Style
    let allStyles: [Style]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runningApps: [RunningAppInfo] = []
    @State private var selectedBundleID: String?
    @State private var isFilePickerPresented = false

    /// Bundle IDs already assigned to any style
    private var assignedBundleIDs: Set<String> {
        Set(allStyles.flatMap { $0.associatedAppBundleIDs })
    }

    /// Bundle IDs already assigned to the current style
    private var currentStyleBundleIDs: Set<String> {
        Set(currentStyle.associatedAppBundleIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Running Apps Section
                    runningAppsSection

                    // Browse Section
                    browseSection
                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            await loadRunningApps()
        }
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false
        ) { result in
            handleFilePickerResult(result)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Application")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Select an app to assign to \"\(currentStyle.name)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Running Apps Section

    private var runningAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Running Applications")
                    .font(.headline)

                Spacer()

                if !runningApps.isEmpty {
                    Text("\(runningApps.filter { !currentStyleBundleIDs.contains($0.bundleID) }.count) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if runningApps.isEmpty {
                ContentUnavailableView {
                    Label("No Running Apps", systemImage: "app.dashed")
                } description: {
                    Text("Launch some applications and they will appear here.")
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
                ], spacing: 16) {
                    ForEach(runningApps) { app in
                        RunningAppCell(
                            app: app,
                            isAssignedToCurrent: currentStyleBundleIDs.contains(app.bundleID),
                            isAssignedToOther: assignedBundleIDs.contains(app.bundleID) && !currentStyleBundleIDs.contains(app.bundleID)
                        )
                        .onTapGesture {
                            if !currentStyleBundleIDs.contains(app.bundleID) {
                                selectApp(bundleID: app.bundleID)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Browse Section

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other Applications")
                .font(.headline)

            Button(action: { isFilePickerPresented = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browse...")
                            .font(.body)
                            .fontWeight(.medium)

                        Text("Select any application from your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separatorColor), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("Apps already assigned to this style are shown as selected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Actions

    private func loadRunningApps() async {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular } // Only regular apps, not background processes
            .compactMap { app -> RunningAppInfo? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return RunningAppInfo(
                    bundleID: bundleID,
                    name: name,
                    icon: app.icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Remove duplicates (same bundle ID)
        var seenBundleIDs: Set<String> = []
        runningApps = apps.filter { app in
            guard !seenBundleIDs.contains(app.bundleID) else { return false }
            seenBundleIDs.insert(app.bundleID)
            return true
        }
    }

    private func selectApp(bundleID: String) {
        onSelect(bundleID)
        dismiss()
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Extract bundle ID from the selected app
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else {
                // Fallback: try to get bundle ID from Info.plist
                let plistURL = url.appendingPathComponent("Contents/Info.plist")
                if let plist = NSDictionary(contentsOf: plistURL),
                   let bundleID = plist["CFBundleIdentifier"] as? String {
                    selectApp(bundleID: bundleID)
                }
                return
            }

            selectApp(bundleID: bundleID)

        case .failure(let error):
            Logger.styles.error("File picker error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Running App Info

private struct RunningAppInfo: Identifiable, Sendable {
    let bundleID: String
    let name: String
    let icon: NSImage?

    var id: String { bundleID }
}

// MARK: - Running App Cell

private struct RunningAppCell: View {
    let app: RunningAppInfo
    let isAssignedToCurrent: Bool
    let isAssignedToOther: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                }

                // Status indicator
                if isAssignedToCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .background(Circle().fill(.white))
                } else if isAssignedToOther {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.white))
                        .help("This app is assigned to another style. Selecting it will move it here.")
                }
            }

            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 80)
        .padding(8)
        .background(isAssignedToCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isAssignedToCurrent ? 0.6 : 1.0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isAssignedToCurrent ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Previews

#Preview {
    AppPickerView(
        styleRegistry: StyleRegistry(),
        currentStyle: Style.casual,
        allStyles: Style.builtIn,
        onSelect: { _ in }
    )
}
