import AppKit
import SwiftUI
import OSLog

final class PushToTypePanel {
    private var panel: NSPanel?
    private var viewModel: PushToTypeViewModel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var becameKeyObserver: NSObjectProtocol?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 400
    private static let panelBaseHeight: CGFloat = 140
    private static let panelMaxHeight: CGFloat = 600
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    /// Approximate height per line of monospaced body text
    private static let lineHeight: CGFloat = 20
    /// Height of a "You:" or "Result:" label line
    private static let labelLineHeight: CGFloat = 18
    /// Height of a divider between turns
    private static let turnDividerHeight: CGFloat = 10
    /// Padding around the conversation history section
    private static let conversationPadding: CGFloat = 24

    func show(
        settings: AppSettings,
        conversationTurns: [ConversationTurn] = [],
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        hide()

        let viewModel = PushToTypeViewModel(
            settings: settings,
            conversationTurns: conversationTurns,
            onSubmit: { [weak self] text in
                onSubmit(text)
                self?.hide()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.hide()
            }
        )
        self.viewModel = viewModel

        let view = PushToTypeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let panelHeight = Self.calculateHeight(for: conversationTurns)
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

        // Position at top center, just below the menu bar
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

        // Focus the TextEditor's underlying NSTextView directly via AppKit.
        // @FocusState in NSHostingView inside a .nonActivatingPanel is unreliable
        // because SwiftUI's focus system may not connect to the panel's responder chain.
        Self.focusFirstTextView(in: hostingView, panel: panel)

        // Intercept Return (submit) and Escape (dismiss) before they reach the text field.
        // Only handle events when this panel is key — if another panel (e.g. mode switcher)
        // is key, let events pass through so its own monitor can handle them.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel, weak panel] event in
            guard let viewModel, panel?.isKeyWindow == true else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // Re-focus the text view when this panel regains key status (e.g. after
        // the mode switcher panel closes and key window falls back to this panel).
        // Don't reposition cursor on re-focus — only on initial show.
        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak hostingView, weak panel] _ in
            guard let hostingView, let panel else { return }
            Self.focusFirstTextView(in: hostingView, panel: panel)
        }

        // Dismiss if the user clicks outside the panel
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = becameKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            becameKeyObserver = nil
        }
        panel?.close()
        panel = nil
        viewModel = nil
    }

    var isVisible: Bool { panel != nil }

    func updateOutputDestinationOverride(_ id: UUID?) {
        viewModel?.outputDestinationOverrideID = id
    }

    // MARK: - Height Calculation

    private static func calculateHeight(for turns: [ConversationTurn]) -> CGFloat {
        guard !turns.isEmpty else { return panelBaseHeight }

        var conversationLines: CGFloat = 0
        for (index, turn) in turns.enumerated() {
            // "You:" label + input lines + "Result:" label + output lines
            conversationLines += labelLineHeight / lineHeight
            conversationLines += CGFloat(turn.input.components(separatedBy: .newlines).count)
            conversationLines += labelLineHeight / lineHeight
            conversationLines += CGFloat(turn.output.components(separatedBy: .newlines).count)

            if index < turns.count - 1 {
                conversationLines += turnDividerHeight / lineHeight
            }
        }

        let conversationHeight = conversationLines * lineHeight + conversationPadding
        return min(panelBaseHeight + conversationHeight, panelMaxHeight)
    }

    // MARK: - Focus Management

    /// Walks the view hierarchy to find the NSTextView created by SwiftUI's TextEditor
    /// and makes it the panel's first responder for immediate keyboard input.
    private static func focusFirstTextView(in view: NSView, panel: NSPanel) {
        DispatchQueue.main.async {
            if let textView = Self.findFirstTextView(in: view) {
                panel.makeFirstResponder(textView)
            }
        }
    }

    private static func findFirstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = findFirstTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}

// MARK: - NSPanel subclass that accepts key events

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - View Model

@Observable
final class PushToTypeViewModel {
    var text: String = ""
    var outputDestinationOverrideID: UUID?
    let conversationTurns: [ConversationTurn]
    let settings: AppSettings
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    var modeLabel: String {
        let destinationID = outputDestinationOverrideID ?? settings.activeMode.defaultOutputDestinationID
        let destination = settings.outputDestination(for: destinationID)
        return "\(settings.activeMode.name) · \(destination.symbol)"
    }

    init(settings: AppSettings, conversationTurns: [ConversationTurn] = [], onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.settings = settings
        self.conversationTurns = conversationTurns
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
    }

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36: // Return
            // Shift+Return inserts newline (pass through to text field)
            if event.modifierFlags.contains(.shift) {
                return false
            }
            // Plain Return submits
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            onSubmit(trimmed)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - SwiftUI View

private struct PushToTypeView: View {
    @Bindable var viewModel: PushToTypeViewModel
    @FocusState private var isTextFieldFocused: Bool

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let textPadding: CGFloat = 12
    private static let hintBarHPadding: CGFloat = 10
    private static let hintBarVPadding: CGFloat = 6
    private static let hintSpacing: CGFloat = 12
    private static let keyCornerRadius: CGFloat = 3
    private static let keyHPadding: CGFloat = 4
    private static let keyVPadding: CGFloat = 1
    private static let labelVPadding: CGFloat = 4
    private static let turnDividerVPadding: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.conversationTurns.isEmpty {
                conversationHistorySection
                Divider()
            }

            TextEditor(text: $viewModel.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
                .padding(Self.textPadding)

            Divider()

            HStack(spacing: Self.hintSpacing) {
                Text(viewModel.modeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                hintLabel("\u{21B5}", "submit")
                hintLabel("esc", "dismiss")
            }
            .padding(.horizontal, Self.hintBarHPadding)
            .padding(.vertical, Self.hintBarVPadding)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private var conversationHistorySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.conversationTurns.enumerated()), id: \.element.id) { index, turn in
                    Text("You:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Self.labelVPadding)

                    Text(turn.input)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, Self.labelVPadding)

                    Text("Result:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Self.labelVPadding)

                    Text(turn.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if index < viewModel.conversationTurns.count - 1 {
                        Divider()
                            .padding(.vertical, Self.turnDividerVPadding)
                    }
                }
            }
            .padding(Self.textPadding)
        }
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
