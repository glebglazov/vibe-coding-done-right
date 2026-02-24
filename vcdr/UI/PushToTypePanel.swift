import AppKit
import SwiftUI
import OSLog

final class PushToTypePanel {
    private var panel: NSPanel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var becameKeyObserver: NSObjectProtocol?

    // MARK: - Constants

    private static let panelWidth: CGFloat = 320
    private static let panelHeight: CGFloat = 100
    private static let panelOffsetBelowMenuBar: CGFloat = 8

    func show(settings: AppSettings, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        hide()

        let viewModel = PushToTypeViewModel(
            settings: settings,
            onSubmit: { [weak self] text in
                onSubmit(text)
                self?.hide()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.hide()
            }
        )

        let view = PushToTypeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)

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
            let y = screenFrame.maxY - menuBarHeight - Self.panelHeight - Self.panelOffsetBelowMenuBar
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
        // the mode switcher panel closes and key window falls back to this panel)
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
    }

    var isVisible: Bool { panel != nil }

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
private final class PushToTypeViewModel {
    var text: String = ""
    let settings: AppSettings
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    var modeName: String {
        settings.activeMode.name
    }

    init(settings: AppSettings, onSubmit: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.settings = settings
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
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let modeNameFontSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(viewModel.modeName)
                    .font(.system(size: Self.modeNameFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\u{21B5} submit")
                    .font(.system(size: Self.modeNameFontSize))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $viewModel.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
