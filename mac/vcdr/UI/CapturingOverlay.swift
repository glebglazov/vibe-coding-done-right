//
//  CapturingOverlay.swift
//  vcdr
//
//  Created by Gleb Glazov on 24/9/25.
//

import SwiftUI
import Combine

struct CapturingOverlay: View {
    let onStopAndPaste: () -> Void
    let onStopAndCopyToClipboard: () -> Void
    let onStopAndSendToTmux: () -> Void
    let onCancel: () -> Void
    let onToggleRecording: () -> Void
    @ObservedObject var audioRecorder: AudioRecorder
    @ObservedObject var controller: MenuBarController
    let previousActiveApp: NSRunningApplication?

    @ObservedObject var modeManager = ModeManager.shared
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 50)
    @State private var animationTimer: Timer?
    @State private var currentLevel: Float = 0.0

    private var headerIconName: String {
        audioRecorder.isRecording ? "waveform.circle.fill" : "mic.circle"
    }

    private var headerIconColor: Color {
        audioRecorder.isRecording ? .red : .blue
    }

    private var headerTitle: String {
        audioRecorder.isRecording ? "Recording..." : "Ready to Record"
    }

    private var headerSubtitle: String {
        audioRecorder.isRecording ? "Press R to stop" : "Press R to start recording"
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: headerIconName)
                .font(.system(size: 48))
                .foregroundColor(headerIconColor)
                .symbolEffect(.pulse, isActive: audioRecorder.isRecording)

            Text(headerTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Text(headerSubtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("X: Disabled • A: Assistant • C: Custom")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var soundwaveView: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue.gradient)
                    .frame(width: 3, height: max(4, audioLevels[index] * 60))
                    .animation(.easeInOut(duration: 0.1), value: audioLevels[index])
            }
        }
        .frame(height: 80)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private var hasTranscription: Bool {
        !controller.capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var transcriptionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Transcription:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
            }

            VStack(alignment: .leading) {
                ScrollView {
                    if hasTranscription {
                        Text(controller.capturedText)
                            .font(.system(size: 11))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(4)
                    } else {
                        Text("Everything you capture will be here")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                .frame(minHeight: 60, maxHeight: 80)
            }
            .padding(8)
            .background(Color.white.opacity(0.8))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var modeSelectionView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text("AI Processing:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                // Disabled mode (X)
                if let disabledMode = modeManager.builtInModes.first(where: { $0.name == "Disabled" }) {
                    ModeButton(
                        mode: disabledMode,
                        isActive: modeManager.activeMode?.id == disabledMode.id,
                        onTap: {
                            modeManager.setMode(disabledMode)
                            let settings = AppSettings.shared
                            settings.activeModeName = disabledMode.name
                            settings.saveSettings()
                        }
                    )
                }

                // Assistant mode (A)
                if let assistantMode = modeManager.builtInModes.first(where: { $0.name == "Assistant" }) {
                    ModeButton(
                        mode: assistantMode,
                        isActive: modeManager.activeMode?.id == assistantMode.id,
                        onTap: {
                            modeManager.setMode(assistantMode)
                            let settings = AppSettings.shared
                            settings.activeModeName = assistantMode.name
                            settings.saveSettings()
                        }
                    )
                }

                // Custom mode slot (C)
                CustomModeSlot(
                    modeManager: modeManager,
                    currentCustomMode: modeManager.activeMode as? CustomMode ?? modeManager.lastUsedCustomMode ?? modeManager.customModes.first,
                    isActive: modeManager.activeMode is CustomMode
                )

                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
    }

    var body: some View {
        VStack(spacing: 20) {
            headerView

            if audioRecorder.isRecording {
                soundwaveView
            }

            transcriptionView

            modeSelectionView

            keyboardShortcutsView
        }
        .padding(24)
        .frame(width: 350)
        .background(.regularMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
        .onAppear {
            startSoundwaveAnimation()
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            stopSoundwaveAnimation()
        }
        .onChange(of: audioRecorder.audioLevel) { _, level in
            currentLevel = level
        }
        .onKeyPress(.init("r")) {
            onToggleRecording()
            return .handled
        }
        .onKeyPress(.init("R")) {
            onToggleRecording()
            return .handled
        }
    }

    private var recordButtonText: String {
        audioRecorder.isRecording ? "Press R to stop recording" : "Press R to start recording"
    }

    private var recordButtonColor: Color {
        audioRecorder.isRecording ? .red : .green
    }

    private var keyboardShortcutsView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "r.circle")
                    .foregroundColor(recordButtonColor)
                Text(recordButtonText)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }

            Divider()

            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.blue)
                Text("Press ⌘C to copy to clipboard")
                    .font(.caption)
                Spacer()
            }

            HStack {
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundColor(.purple)
                Text("Press ⌘V to paste into current program")
                    .font(.caption)
                Spacer()
            }

            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("Press ⌘T to send to Tmux")
                    .font(.caption)
                Spacer()
            }

            HStack {
                Image(systemName: "xmark")
                    .foregroundColor(.red)
                Text("Press ⌘S to cancel")
                    .font(.caption)
                Spacer()
            }
        }
        .padding(.horizontal)
    }

    private func startSoundwaveAnimation() {
        // Initialize with base level
        audioLevels = Array(repeating: 0.1, count: 50)

        // Start continuous animation timer
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateSoundwaveWithLevel(currentLevel)
        }
    }

    private func stopSoundwaveAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func updateSoundwaveWithLevel(_ level: Float) {
        let normalizedLevel = max(0.1, min(1.0, CGFloat(level)))

        // Shift existing levels left
        audioLevels.removeFirst()

        // Add new level with some variation for visual effect
        let variation = CGFloat.random(in: -0.1...0.1)
        let newLevel = max(0.1, min(1.0, normalizedLevel + variation))
        audioLevels.append(newLevel)
    }

}

// MARK: - Helper Views

struct ModeButton: View {
    let mode: any Mode
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(mode.name)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.purple : Color.gray.opacity(0.2)
                )
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CustomModeSlot: View {
    @ObservedObject var modeManager: ModeManager
    let currentCustomMode: CustomMode?
    let isActive: Bool

    var body: some View {
        Button(action: {
            // Cycle through custom modes when clicked
            modeManager.cycleCustomMode()
            if let activeMode = modeManager.activeMode {
                let settings = AppSettings.shared
                settings.activeModeName = activeMode.name
                settings.saveSettings()
            }
        }) {
            Text(currentCustomMode?.name ?? "No Custom")
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundColor(isActive ? .white : (currentCustomMode == nil ? .secondary : .primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.purple : Color.gray.opacity(0.2)
                )
                .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(modeManager.customModes.isEmpty)
    }
}

#Preview {
    CapturingOverlay(
        onStopAndPaste: { },
        onStopAndCopyToClipboard: { },
        onStopAndSendToTmux: { },
        onCancel: { },
        onToggleRecording: { },
        audioRecorder: AudioRecorder(),
        controller: MenuBarController(),
        previousActiveApp: nil
    )
}
