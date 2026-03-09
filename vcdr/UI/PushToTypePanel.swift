import AppKit
import SwiftUI
import OSLog

final class PushToTypePanel {
    private var panel: NSPanel?
    private var viewModel: PushToTypeViewModel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var becameKeyObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?

    /// Called when the panel loses focus (click outside, app switch).
    /// The coordinator decides whether to collapse or dismiss.
    var onFocusLost: (() -> Void)?

    /// Called when the minimized pill is clicked or the panel regains key status while minimized.
    var onPillClicked: (() -> Void)?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 400
    private static let panelBaseHeight: CGFloat = 140
    private static let panelMaxHeight: CGFloat = 600
    private static let panelOffsetBelowMenuBar: CGFloat = 8
    private static let minimizedPanelWidth: CGFloat = 200
    private static let minimizedPanelHeight: CGFloat = 40
    /// Delay to let resize animation finish and SwiftUI lay out the TextEditor
    private static let expandFocusDelay: Duration = .milliseconds(200)
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

        // When the panel regains key status: if minimized, notify coordinator
        // to expand; if expanded, re-focus the text view (e.g. after mode switcher closes).
        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak hostingView, weak panel] _ in
            guard let self else { return }
            if self.viewModel?.isMinimized == true {
                self.onPillClicked?()
                return
            }
            guard let hostingView, let panel else { return }
            Self.focusFirstTextView(in: hostingView, panel: panel)
        }

        // Auto-collapse when the panel loses key window status.
        // Skip if the mode switcher is open (it takes key from us) or already minimized.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }

        // Collapse if the user clicks outside the panel.
        // Skip if mode switcher is open or already minimized.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
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
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        panel?.close()
        panel = nil
        viewModel = nil
    }

    var isVisible: Bool { panel != nil }

    var isMinimized: Bool { viewModel?.isMinimized ?? false }

    var currentText: String { viewModel?.text ?? "" }

    // MARK: - Minimize / Expand

    func minimize() {
        guard viewModel?.isMinimized != true else { return }
        viewModel?.isMinimized = true
        resizePanelToMinimized()
        panel?.resignKey()
    }

    func expand() {
        guard viewModel?.isMinimized == true else { return }
        viewModel?.isMinimized = false
        resizePanelToExpanded()
        panel?.makeKey()
        // Delay focus to let resize animation finish and SwiftUI
        // lay out the TextEditor in the expanded view hierarchy.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.expandFocusDelay)
            guard let self, let contentView = self.panel?.contentView, let panel = self.panel else { return }
            Self.focusFirstTextView(in: contentView, panel: panel)
        }
    }

    func updateCapturedSelection(_ selection: String?) {
        viewModel?.capturedSelection = selection
    }

    func signalClipboardCapture() {
        viewModel?.clipboardCaptureCount += 1
    }

    func setDestinationSubmitHandler(_ handler: @escaping (String, UUID) -> Void) {
        viewModel?.onDestinationSubmit = handler
    }

    private func resizePanelToMinimized() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.minimizedPanelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - Self.minimizedPanelHeight - Self.panelOffsetBelowMenuBar
        let newFrame = NSRect(x: x, y: y, width: Self.minimizedPanelWidth, height: Self.minimizedPanelHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func resizePanelToExpanded() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let turns = viewModel?.conversationTurns ?? []
        let selection = viewModel?.capturedSelection
        let newHeight = Self.calculateHeight(for: turns, capturedSelection: selection)
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - newHeight - Self.panelOffsetBelowMenuBar
        let newFrame = NSRect(x: x, y: y, width: Self.panelWidth, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

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
    var isMinimized: Bool = false
    var clipboardCaptureCount: Int = 0
    var outputDestinationOverrideID: UUID?
    var parameterLabels: String?
    var modeSwitcherViewModel: ModeSwitcherViewModel?
    let conversationTurns: [ConversationTurn]
    var capturedSelection: String?
    let settings: AppSettings
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    /// Called when a destination hotkey is pressed — submits text to that destination
    var onDestinationSubmit: ((String, UUID) -> Void)?

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

        // Check destination hotkeys (Ctrl+P for paste, Ctrl+C for copy, etc.)
        if let matchedDestination = matchDestinationHotkey(event) {
            let effectiveText = resolveSubmissionText()
            guard !effectiveText.isEmpty else { return true }
            onDestinationSubmit?(effectiveText, matchedDestination)
            return true
        }

        switch event.keyCode {
        case 36: // Return
            // Shift+Return inserts newline (pass through to text field)
            if event.modifierFlags.contains(.shift) {
                return false
            }
            // Plain Return submits
            let effectiveText = resolveSubmissionText()
            guard !effectiveText.isEmpty else { return true }
            onSubmit(effectiveText)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            return false
        }
    }

    /// Typed text takes priority; falls back to captured selection so the user
    /// can submit clipboard-gathered content without typing anything.
    private func resolveSubmissionText() -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return capturedSelection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Checks if the event matches any output destination's activation hotkey.
    /// Uses superset modifier matching — extra modifiers are allowed.
    private func matchDestinationHotkey(_ event: NSEvent) -> UUID? {
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        for destination in settings.outputDestinations {
            let hotkey = destination.activationHotkey
            guard hotkey.isAssigned else { continue }
            let requiredFlags = UInt(hotkey.modifiers)
            if event.keyCode == hotkey.keyCode && (eventFlags & requiredFlags) == requiredFlags {
                return destination.id
            }
        }
        return nil
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

    // MARK: - Constants (Pill)

    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillIconSize: CGFloat = 14
    private static let captureBadgeSize: CGFloat = 12
    private static let captureCountFontSize: CGFloat = 9

    var body: some View {
        if viewModel.isMinimized {
            minimizedPillView
        } else {
            expandedView
        }
    }

    private var minimizedPillView: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.cursor")
                .font(.system(size: Self.pillIconSize))
                .foregroundStyle(.secondary)

            if viewModel.clipboardCaptureCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: Self.captureBadgeSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    if viewModel.clipboardCaptureCount > 1 {
                        Text("×\(viewModel.clipboardCaptureCount)")
                            .font(.system(size: Self.captureCountFontSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.pillHPadding)
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
        .shadow(radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: viewModel.clipboardCaptureCount)
    }

    private var expandedView: some View {
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
