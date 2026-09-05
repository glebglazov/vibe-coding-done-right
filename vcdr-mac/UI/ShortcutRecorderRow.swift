import SwiftUI
import Carbon

/// Suspends every app-owned hotkey for as long as the returned token is held,
/// so a combination VCDR has bound reaches the shortcut recorder instead.
/// Installed by `MainWindowView`; consumed by `ShortcutRecorderRow`.
private struct SuspendHotkeysKey: EnvironmentKey {
    static let defaultValue: (() -> HotkeySuspension)? = nil
}

extension EnvironmentValues {
    var suspendHotkeys: (() -> HotkeySuspension)? {
        get { self[SuspendHotkeysKey.self] }
        set { self[SuspendHotkeysKey.self] = newValue }
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
    /// Written as one value, so a captured combo is never briefly armed as its
    /// new key with the old modifiers still attached.
    @Binding var hotkey: HotkeyBinding
    @State private var isRecording = false
    @State private var eventMonitor = ShortcutEventMonitor()
    @Environment(\.suspendHotkeys) private var suspendHotkeys
    /// Held for exactly as long as this row is recording. Dropping it is what
    /// gives the app its hotkeys back — including when the row itself goes away
    /// mid-recording, which `onDisappear` is not guaranteed to catch.
    @State private var suspension: HotkeySuspension?

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
                    .disabled(!hotkey.isAssigned)
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
        hotkey.isAssigned ? hotkey.displayString : "Not set"
    }

    private func clearShortcut() {
        hotkey = .unassigned
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
        suspension = suspendHotkeys?()
        eventMonitor.start { [self] capturedKeyCode, capturedModifiers in
            hotkey = HotkeyBinding(keyCode: capturedKeyCode, modifiers: capturedModifiers)
            stopRecording()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        eventMonitor.stop()
        suspension = nil
    }
}
