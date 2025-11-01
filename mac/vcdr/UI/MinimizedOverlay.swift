//
//  MinimizedOverlay.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// A minimized overlay that shows recording status with a mini soundwave
/// Stays visible while capture is active
struct MinimizedOverlay: View {
    let isRecording: Bool
    @ObservedObject var audioRecorder: AudioRecorder
    let onToggleRecording: () -> Void
    let onAddClipboard: () -> Void
    let onPreview: () -> Void
    let onStopCapture: () -> Void

    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 15)
    @State private var animationTimer: Timer?
    @State private var currentLevel: Float = 0.0

    var body: some View {
        HStack(spacing: 8) {
            // Add from clipboard button
            Button(action: onAddClipboard) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Add clipboard to capture")

            // Toggle recording button
            Button(action: onToggleRecording) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 16, height: 16)

                    if isRecording {
                        // Stop icon (square)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                    } else {
                        // Play icon (triangle)
                        Image(systemName: "play.fill")
                            .font(.system(size: 6))
                            .foregroundColor(.white)
                            .offset(x: 0.5)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .help(isRecording ? "Stop recording" : "Start recording")

            // Mini soundwave
            miniSoundwaveView

            // Preview button
            Button(action: onPreview) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.purple)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Preview capture")

            // Stop capture button
            Button(action: onStopCapture) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Stop capture")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
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
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(isRecording ? Color.blue.gradient : Color.gray.opacity(0.3).gradient)
                    .frame(width: 2, height: max(2, audioLevels[index] * 20))
                    .animation(.easeInOut(duration: 0.1), value: audioLevels[index])
            }
        }
        .frame(height: 20)
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
    VStack(spacing: 20) {
        MinimizedOverlay(
            isRecording: true,
            audioRecorder: AudioRecorder(),
            onToggleRecording: {},
            onAddClipboard: {},
            onPreview: {},
            onStopCapture: {}
        )
        MinimizedOverlay(
            isRecording: false,
            audioRecorder: AudioRecorder(),
            onToggleRecording: {},
            onAddClipboard: {},
            onPreview: {},
            onStopCapture: {}
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.3))
}
