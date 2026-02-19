import SwiftUI
import Carbon

struct ShortcutRecorderRow: View {
    let label: String
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @State private var isRecording = false
    @State private var eventMonitor: Any?

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
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !flags.isEmpty else { return event }

            keyCode = event.keyCode

            var cgFlags: UInt64 = 0
            if flags.contains(.command) { cgFlags |= CGEventFlags.maskCommand.rawValue }
            if flags.contains(.option) { cgFlags |= CGEventFlags.maskAlternate.rawValue }
            if flags.contains(.shift) { cgFlags |= CGEventFlags.maskShift.rawValue }
            if flags.contains(.control) { cgFlags |= CGEventFlags.maskControl.rawValue }
            modifiers = cgFlags

            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
