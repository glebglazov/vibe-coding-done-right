import SwiftUI
import Carbon

/// Environment handler that disables every app-owned hotkey while the user
/// is recording a new shortcut. Installed by `MainWindowView`; consumed by
/// `ShortcutRecorderRow`. Called with `true` on start and `false` on stop/cancel.
private struct HotkeySuppressionKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var hotkeySuppressionHandler: ((Bool) -> Void)? {
        get { self[HotkeySuppressionKey.self] }
        set { self[HotkeySuppressionKey.self] = newValue }
    }
}

/// Manages the lifecycle of an NSEvent monitor for recording keyboard shortcuts.
/// Separates event system interaction from the SwiftUI view.
private final class ShortcutEventMonitor {
    private var monitor: Any?

    /// Starts listening for key-down events with modifier flags.
    /// Calls `onCapture` with the keyCode and CGEventFlags when a valid combo is pressed.
    func start(onCapture: @escaping (UInt16, UInt64) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !flags.isEmpty else { return event }

            var cgFlags: UInt64 = 0
            if flags.contains(.command) { cgFlags |= CGEventFlags.maskCommand.rawValue }
            if flags.contains(.option) { cgFlags |= CGEventFlags.maskAlternate.rawValue }
            if flags.contains(.shift) { cgFlags |= CGEventFlags.maskShift.rawValue }
            if flags.contains(.control) { cgFlags |= CGEventFlags.maskControl.rawValue }

            onCapture(event.keyCode, cgFlags)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stop()
    }
}

struct ShortcutRecorderRow: View {
    let label: String
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @State private var isRecording = false
    @State private var eventMonitor = ShortcutEventMonitor()
    @Environment(\.hotkeySuppressionHandler) private var hotkeySuppressionHandler

    // MARK: - Constants

    private static let unassignedKeyCode: UInt16 = 0
    private static let unassignedModifiers: UInt64 = 0

    private var isAssigned: Bool {
        keyCode != Self.unassignedKeyCode || modifiers != Self.unassignedModifiers
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Button(action: { toggleRecording() }) {
                    Text(isRecording ? "Press a key combo..." : displayString)
                        .frame(minWidth: 140)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .background(isRecording ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )

                if !isRecording {
                    Button(action: { clearShortcut() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isAssigned)
                    .help("Clear shortcut")
                }

                if isRecording {
                    Button("Cancel") {
                        stopRecording()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var displayString: String {
        guard isAssigned else { return "Not set" }
        return GlobalHotkeyManager.shortcutDisplayString(
            keyCode: CGKeyCode(keyCode),
            modifiers: CGEventFlags(rawValue: modifiers)
        )
    }

    private func clearShortcut() {
        keyCode = Self.unassignedKeyCode
        modifiers = Self.unassignedModifiers
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        hotkeySuppressionHandler?(true)
        eventMonitor.start { [self] capturedKeyCode, capturedModifiers in
            keyCode = capturedKeyCode
            modifiers = capturedModifiers
            stopRecording()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        eventMonitor.stop()
        hotkeySuppressionHandler?(false)
    }
}
