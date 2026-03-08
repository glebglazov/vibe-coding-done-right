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
        capturedSelection: String? = nil,
        topOffset: CGFloat = 0,
        onSubmit: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        hide()

        let viewModel = PushToTypeViewModel(
            settings: settings,
            conversationTurns: conversationTurns,
            capturedSelection: capturedSelection,
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
        let panelHeight = Self.calculateHeight(for: conversationTurns, capturedSelection: capturedSelection)
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

        // Position at top center, just below the menu bar (or below the output panel)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - Self.panelWidth / 2
            let y = screenFrame.maxY - menuBarHeight - panelHeight - Self.panelOffsetBelowMenuBar - topOffset
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

    func updateParameterLabels(_ labels: String?) {
        viewModel?.parameterLabels = labels
    }

    // MARK: - Contextual Mode Switcher

    func showModeSwitcher(viewModel: ModeSwitcherViewModel) {
        self.viewModel?.modeSwitcherViewModel = viewModel
    }

    func hideModeSwitcher() {
        self.viewModel?.modeSwitcherViewModel = nil
        // Re-focus text view after mode list dismisses
        if let contentView = panel?.contentView, let panel {
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    var isModeSwitcherVisible: Bool {
        viewModel?.modeSwitcherViewModel != nil
    }

    // MARK: - Height Calculation

    private static func calculateHeight(for turns: [ConversationTurn], capturedSelection: String? = nil) -> CGFloat {
        var extraHeight: CGFloat = 0

        // Captured selection blockquote ("Context:" label + selection lines + padding)
        if let selection = capturedSelection {
            let selectionLines = CGFloat(selection.components(separatedBy: .newlines).count)
            extraHeight += labelLineHeight  // "Context:" label
            extraHeight += selectionLines * lineHeight * 0.9  // callout font is slightly smaller
            extraHeight += conversationPadding
        }

        guard !turns.isEmpty else { return min(panelBaseHeight + extraHeight, panelMaxHeight) }

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
        return min(panelBaseHeight + conversationHeight + extraHeight, panelMaxHeight)
    }

    // MARK: - Constants (Focus)

    /// Maximum number of attempts to find and focus the NSTextView
    private static let focusMaxAttempts = 10
    /// Delay between focus retry attempts, giving SwiftUI time to lay out the view hierarchy
    private static let focusRetryDelay: Duration = .milliseconds(10)

    // MARK: - Focus Management

    /// Walks the view hierarchy to find the NSTextView created by SwiftUI's TextEditor
    /// and makes it the panel's first responder for immediate keyboard input.
    /// Retries with a short delay because SwiftUI may need multiple run loop iterations
    /// to fully insert the NSTextView into the hosting view's hierarchy.
    private static func focusFirstTextView(in view: NSView, panel: NSPanel) {
        Task { @MainActor in
            for _ in 0..<focusMaxAttempts {
                if let textView = findFirstTextView(in: view) {
                    panel.makeFirstResponder(textView)
                    // Verify focus actually took — another responder may have stolen it
                    if panel.firstResponder === textView {
                        return
                    }
                }
                try? await Task.sleep(for: focusRetryDelay)
            }
            Logger.ui.warning("Push-to-type panel: failed to focus text view after \(focusMaxAttempts) attempts")
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

// MARK: - View Model

@Observable
final class PushToTypeViewModel {
    var text: String = ""
    var outputDestinationOverrideID: UUID?
    var parameterLabels: String?
    var modeSwitcherViewModel: ModeSwitcherViewModel?
    let conversationTurns: [ConversationTurn]
    let capturedSelection: String?
    let settings: AppSettings
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    var modeLabel: String {
        let destinationID = outputDestinationOverrideID ?? settings.activeMode.defaultOutputDestinationID
        let destination = settings.outputDestination(for: destinationID)
        let parts = [settings.activeMode.name, parameterLabels, destination.symbol].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    init(settings: AppSettings, conversationTurns: [ConversationTurn] = [], capturedSelection: String? = nil, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.settings = settings
        self.conversationTurns = conversationTurns
        self.capturedSelection = capturedSelection
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
    }

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Delegate to mode switcher when it's showing
        if let msVM = modeSwitcherViewModel {
            return msVM.handleKeyEvent(event)
        }

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
    private static let blockquoteBorderWidth: CGFloat = 2
    private static let blockquoteBorderSpacing: CGFloat = 6
    private static let blockquoteBorderOpacity: Double = 0.4
    private static let blockquoteLeadingPadding: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            if let msVM = viewModel.modeSwitcherViewModel {
                ModeSwitcherView(viewModel: msVM)
                    .padding(Self.textPadding)
            } else {
                if !viewModel.conversationTurns.isEmpty {
                    conversationHistorySection
                    Divider()
                }

                TextEditor(text: $viewModel.text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($isTextFieldFocused)
                    .padding(Self.textPadding)

                if let selection = viewModel.capturedSelection {
                    Divider()
                    selectionBlockquote(selection)
                        .padding(Self.textPadding)
                }
            }

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

    private func selectionBlockquote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Self.blockquoteBorderSpacing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(Self.blockquoteBorderOpacity))
                .frame(width: Self.blockquoteBorderWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("Context:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(text)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Self.blockquoteLeadingPadding)
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
