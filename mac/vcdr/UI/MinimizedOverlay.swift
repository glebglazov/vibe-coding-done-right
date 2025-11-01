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

    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 15)
    @State private var animationTimer: Timer?
    @State private var currentLevel: Float = 0.0

    var body: some View {
        HStack(spacing: 8) {
            // Recording indicator
            Circle()
                .fill(isRecording ? Color.red : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(isRecording ? Color.red.opacity(0.3) : Color.clear, lineWidth: 4)
                        .scaleEffect(isRecording ? 1.5 : 1.0)
                        .opacity(isRecording ? 0 : 1)
                        .animation(
                            isRecording ? .easeInOut(duration: 1.0).repeatForever(autoreverses: false) : .default,
                            value: isRecording
                        )
                )

            // Mini soundwave
            miniSoundwaveView
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
        // Initialize with base level
        audioLevels = Array(repeating: 0.1, count: 15)

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
    VStack(spacing: 20) {
        MinimizedOverlay(isRecording: true, audioRecorder: AudioRecorder())
        MinimizedOverlay(isRecording: false, audioRecorder: AudioRecorder())
        MinimizedOverlay(isRecording: true, audioRecorder: AudioRecorder())
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.gray.opacity(0.3))
}
