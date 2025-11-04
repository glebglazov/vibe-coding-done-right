//
//  MiniOverlay.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// A mini overlay that shows recording status with a mini soundwave
/// Stays visible while capture is active
struct MiniOverlay: View {
    // MARK: - Constants
    private static let buttonFeedbackDuration: TimeInterval = 2.0

    // MARK: - Properties
    let isRecording: Bool
    @ObservedObject var audioRecorder: AudioRecorder
    @ObservedObject var controller: MenuBarController
    let onToggleRecording: () -> Void
    let onAddClipboard: () -> Void
    let onAddLastClipboard: () -> Void
    let onAddKeyboardInput: () -> Void
    let onPreview: () -> Void
    let onStopCapture: () -> Void

    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 15)
    @State private var animationTimer: Timer?
    @State private var currentLevel: Float = 0.0
    @State private var clipboardJustAdded = false
    @State private var lastClipboardJustAdded = false

    var body: some View {
        HStack(spacing: 10) {
            // Add last clipboard entry button
            Button(action: {
                onAddLastClipboard()
                lastClipboardJustAdded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.buttonFeedbackDuration) {
                    lastClipboardJustAdded = false
                }
            }) {
                Image(systemName: lastClipboardJustAdded ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 21, height: 21)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Add last clipboard entry to capture")

            // Add selected text button
            Button(action: {
                onAddClipboard()
                clipboardJustAdded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.buttonFeedbackDuration) {
                    clipboardJustAdded = false
                }
            }) {
                Image(systemName: clipboardJustAdded ? "checkmark" : "selection.pin.in.out")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.green)
                    .frame(width: 21, height: 21)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Add selected text to capture")

            // Toggle recording button
            Button(action: onToggleRecording) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 21, height: 21)

                    if isRecording {
                        // Stop icon (square)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                    } else {
                        // Play icon (triangle)
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                            .offset(x: 0.5)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .help(isRecording ? "Stop recording" : "Start recording")

            // Mini soundwave
            miniSoundwaveView

            // Keyboard input button
            Button(action: onAddKeyboardInput) {
                Image(systemName: controller.keyboardInputJustAdded ? "checkmark" : "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 21, height: 21)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Add keyboard input")

            // Preview button
            Button(action: onPreview) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.purple)
                    .frame(width: 21, height: 21)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Preview capture")

            // Stop capture button
            Button(action: onStopCapture) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.gray)
                    .frame(width: 21, height: 21)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Stop capture")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 2)
        )
        .onAppear {
            startSoundwaveAnimation()
        }
        .onDisappear {
            stopSoundwaveAnimation()
        }
        .onChange(of: audioRecorder.audioLevel) { _, level in
            currentLevel = level
        }
    }

    private var miniSoundwaveView: some View {
        HStack(alignment: .center, spacing: 1.3) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.65)
                    .fill(isRecording ? Color.blue.gradient : Color.gray.opacity(0.3).gradient)
                    .frame(width: 3, height: max(3, audioLevels[index] * 26))
                    .animation(.easeInOut(duration: 0.1), value: audioLevels[index])
            }
        }
        .frame(height: 26)
    }


    private func startSoundwaveAnimation() {
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
    let controller = MenuBarController()

    return VStack(spacing: 20) {
        MiniOverlay(
            isRecording: true,
            audioRecorder: AudioRecorder(),
            controller: controller,
            onToggleRecording: {},
            onAddClipboard: {},
            onAddLastClipboard: {},
            onAddKeyboardInput: {},
            onPreview: {},
            onStopCapture: {}
        )
        MiniOverlay(
            isRecording: false,
            audioRecorder: AudioRecorder(),
            controller: controller,
            onToggleRecording: {},
            onAddClipboard: {},
            onAddLastClipboard: {},
            onAddKeyboardInput: {},
            onPreview: {},
            onStopCapture: {}
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.3))
}
