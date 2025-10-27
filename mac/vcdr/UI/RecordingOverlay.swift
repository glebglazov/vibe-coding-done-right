//
//  RecordingOverlay.swift
//  vcdr
//
//  Created by Gleb Glazov on 24/9/25.
//

import SwiftUI
import Combine

struct RecordingOverlay: View {
    let onStopAndPaste: () -> Void
    let onStopAndCopyToClipboard: () -> Void
    let onStopAndSendToTmux: () -> Void
    let onCancel: () -> Void
    @ObservedObject var audioRecorder: AudioRecorder
    let previousActiveApp: NSRunningApplication?

    @ObservedObject var modeManager = ModeManager.shared
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 50)
    @State private var animationTimer: Timer?
    @State private var currentLevel: Float = 0.0

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse)

                Text("Recording...")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("X: Disabled • A: Assistant")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Soundwave visualization
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

            // Mode Selection
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
                    ForEach(modeManager.availableModes, id: \.id) { mode in
                        Button(action: {
                            modeManager.setMode(mode)
                            let settings = AppSettings.shared
                            settings.activeModeName = mode.name
                            settings.saveSettings()
                        }) {
                            Text(mode.name)
                                .font(.caption)
                                .fontWeight(modeManager.activeMode?.id == mode.id ? .semibold : .regular)
                                .foregroundColor(modeManager.activeMode?.id == mode.id ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    modeManager.activeMode?.id == mode.id
                                    ? Color.purple
                                    : Color.gray.opacity(0.2)
                                )
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.05))
            .cornerRadius(8)

            // Keyboard shortcuts
            VStack(spacing: 8) {
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

#Preview {
    RecordingOverlay(
        onStopAndPaste: { },
        onStopAndCopyToClipboard: { },
        onStopAndSendToTmux: { },
        onCancel: { },
        audioRecorder: AudioRecorder(),
        previousActiveApp: nil
    )
}
