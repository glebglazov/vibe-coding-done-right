import AppKit
import SwiftUI
import OSLog

@MainActor
final class OutputPanelPanel {
    private var panel: NSPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    /// Called when "f" is pressed — start voice dictation follow-up with (text, modeID)
    var onFollowUpDictation: ((String, UUID) -> Void)?
    /// Called when "F" is pressed — start push-to-type follow-up with (text, modeID)
    var onFollowUpType: ((String, UUID) -> Void)?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 400
    private static let panelMinHeight: CGFloat = 80
    private static let panelMaxHeight: CGFloat = 300
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    /// Approximate height per line of monospaced body text
    private static let lineHeight: CGFloat = 20
    /// Padding around text content (top + bottom)
    private static let contentPadding: CGFloat = 32
    /// Height of the hint bar at the bottom
    private static let hintBarHeight: CGFloat = 30

    func show(
        text: String,
        outputDestinations: [OutputDestination],
        targetAppPID: pid_t?,
        modeID: UUID
    ) {
        hide()

        let filteredDestinations = outputDestinations.filter { $0.type != .outputPanel }

        let viewModel = OutputPanelViewModel(
            text: text,
            outputDestinations: filteredDestinations,
            onCopy: { [weak self] in
                self?.copyToClipboard(text)
            },
            onFireDestination: { [weak self] destination in
                self?.fireDestination(destination, text: text, targetAppPID: targetAppPID)
            },
            onFollowUpDictation: { [weak self] in
                self?.hide()
                self?.onFollowUpDictation?(text, modeID)
            },
            onFollowUpType: { [weak self] in
                self?.hide()
                self?.onFollowUpType?(text, modeID)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let view = OutputPanelView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: text)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.panelWidth / 2
            let y = screenFrame.maxY - menuBarHeight - panelHeight - Self.panelOffsetBelowMenuBar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel else { return event }
            return viewModel.handleKeyEvent(event) ? nil : event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }

        Logger.actions.info("Output panel shown")
    }

    func hide() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel != nil }

    // MARK: - Height Calculation

    private static func calculateHeight(for text: String) -> CGFloat {
        let lineCount = CGFloat(text.components(separatedBy: .newlines).count)
        let estimatedTextHeight = lineCount * lineHeight
        let totalHeight = estimatedTextHeight + contentPadding + hintBarHeight
        return min(max(totalHeight, panelMinHeight), panelMaxHeight)
    }

    // MARK: - Actions

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.actions.info("Output panel: text copied to clipboard")
    }

    private func fireDestination(_ destination: OutputDestination, text: String, targetAppPID: pid_t?) {
        hide()
        Task {
            do {
                let action: any PostTranscriptionAction
                switch destination.type {
                case .paste:
                    action = PasteAction(targetAppPID: targetAppPID)
                case .bashScript:
                    action = OutputBashAction(
                        name: destination.name,
                        commandTemplate: destination.bashCommand
                    )
                case .outputPanel:
                    return
                }
                try await action.execute(text: text)
                Logger.actions.info("Output panel: fired destination '\(destination.name)'")
            } catch {
                Logger.actions.error("Output panel: destination failed: \(error)")
            }
        }
    }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View Model

@Observable
private final class OutputPanelViewModel {
    let text: String
    let outputDestinations: [OutputDestination]
    let onCopy: () -> Void
    let onFireDestination: (OutputDestination) -> Void
    let onFollowUpDictation: () -> Void
    let onFollowUpType: () -> Void
    let onDismiss: () -> Void

    init(
        text: String,
        outputDestinations: [OutputDestination],
        onCopy: @escaping () -> Void,
        onFireDestination: @escaping (OutputDestination) -> Void,
        onFollowUpDictation: @escaping () -> Void,
        onFollowUpType: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.text = text
        self.outputDestinations = outputDestinations
        self.onCopy = onCopy
        self.onFireDestination = onFireDestination
        self.onFollowUpDictation = onFollowUpDictation
        self.onFollowUpType = onFollowUpType
        self.onDismiss = onDismiss
    }

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        // Use `characters` (not `charactersIgnoringModifiers`) to detect "F" (Shift+F)
        let rawChars = event.characters ?? ""

        switch event.keyCode {
        case 53: // Escape
            onDismiss()
            return true
        default:
            if chars == "c" {
                onCopy()
                onDismiss()
                return true
            }
            // Follow-up shortcuts: "F" (Shift+F) = type, "f" = dictation
            // Check rawChars which reflects Shift state, before destination
            // activation keys which use charactersIgnoringModifiers
            if rawChars == "F" {
                onFollowUpType()
                return true
            }
            if rawChars == "f" {
                onFollowUpDictation()
                return true
            }
            // Check destination activation keys
            if let char = chars.first {
                let key = String(char)
                if let destination = outputDestinations.first(where: { $0.activationKey == key }) {
                    onFireDestination(destination)
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - SwiftUI View

private struct OutputPanelView: View {
    let viewModel: OutputPanelViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let textPadding: CGFloat = 12
    private static let hintBarHPadding: CGFloat = 10
    private static let hintBarVPadding: CGFloat = 6
    private static let hintSpacing: CGFloat = 12
    private static let keyCornerRadius: CGFloat = 3
    private static let keyHPadding: CGFloat = 4
    private static let keyVPadding: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(viewModel.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Self.textPadding)
            }

            Divider()

            HStack(spacing: Self.hintSpacing) {
                hintLabel("c", "copy")
                hintLabel("f", "follow-up")
                hintLabel("F", "type")
                ForEach(viewModel.outputDestinations.filter { !$0.activationKey.isEmpty }) { dest in
                    hintLabel(dest.activationKey, dest.name.lowercased())
                }
                Spacer()
                hintLabel("esc", "dismiss")
            }
            .padding(.horizontal, Self.hintBarHPadding)
            .padding(.vertical, Self.hintBarVPadding)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    private func hintLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, Self.keyHPadding)
                .padding(.vertical, Self.keyVPadding)
                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
