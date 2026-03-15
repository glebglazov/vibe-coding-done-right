import SwiftUI

// MARK: - Cancelled Indicator View

struct CancelledIndicatorView: View {
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let iconSize: CGFloat = 16

    var body: some View {
        HStack {
            Image(systemName: "xmark")
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.pillHPadding)
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
        .shadow(radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Copied Indicator View

struct CopiedIndicatorView: View {
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let iconSize: CGFloat = 16
    private static let transitionDelay: Duration = .milliseconds(300)

    @State private var showCheckmark = false

    var body: some View {
        VStack {
            HStack {
                if showCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: Self.iconSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Self.pillHPadding)
            .frame(height: Self.pillHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .shadow(radius: 2)
            .animation(.easeInOut(duration: 0.2), value: showCheckmark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            try? await Task.sleep(for: Self.transitionDelay)
            showCheckmark = true
        }
    }
}

// MARK: - Copy Error Indicator View

struct CopyErrorIndicatorView: View {
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let iconSize: CGFloat = 16
    private static let errorPillHPadding: CGFloat = 8
    private static let errorPillVPadding: CGFloat = 3
    private static let errorPillCornerRadius: CGFloat = 6
    private static let errorPillFontSize: CGFloat = 11
    private static let pillSpacing: CGFloat = 4

    let message: String

    var body: some View {
        VStack(spacing: Self.pillSpacing) {
            HStack {
                Image(systemName: "xmark")
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, Self.pillHPadding)
            .frame(height: Self.pillHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .shadow(radius: 2)

            Text(message)
                .font(.system(size: Self.errorPillFontSize))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Self.errorPillHPadding)
                .padding(.vertical, Self.errorPillVPadding)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.errorPillCornerRadius))
                .shadow(radius: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Shake Effect

/// Horizontal shake effect triggered by incrementing `shakeCount`.
/// Each increment produces a brief left-right oscillation.
struct ShakeEffect: GeometryEffect {
    private static let amplitude: CGFloat = 4
    private static let oscillations: CGFloat = 3

    // Must be a plain CGFloat — not derived from Int — so SwiftUI can
    // interpolate smoothly between old and new values during animation.
    var animatableData: CGFloat

    init(shakeCount: Int) {
        self.animatableData = CGFloat(shakeCount)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = Self.amplitude * sin(animatableData * .pi * Self.oscillations)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - Recording Indicator View

struct RecordingIndicatorView: View {
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillSpacing: CGFloat = 6
    private static let iconSize: CGFloat = 16
    private static let phaseTransitionDuration: Double = 0.2

    private static let errorPillSpacing: CGFloat = 4
    private static let errorPillHPadding: CGFloat = 8
    private static let errorPillVPadding: CGFloat = 3
    private static let errorPillCornerRadius: CGFloat = 6
    private static let errorPillFontSize: CGFloat = 11
    private static let captureBadgeSize: CGFloat = 12
    private static let captureCountFontSize: CGFloat = 9

    let phaseState: IndicatorPhaseState
    let captureState: IndicatorCaptureState
    let modeSwitcherState: IndicatorModeSwitcherState
    let settings: AppSettings
    let overrides: ConversationOverrides
    let audioRecorder: AudioRecorder

    var body: some View {
        VStack(spacing: Self.errorPillSpacing) {
            HStack(spacing: Self.pillSpacing) {
                switch phaseState.phase {
                case .recording:
                    if captureState.captureCount > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: Self.captureBadgeSize, weight: .medium))
                                .foregroundStyle(.secondary)
                            if captureState.captureCount > 1 {
                                Text("×\(captureState.captureCount)")
                                    .font(.system(size: Self.captureCountFontSize, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity)
                    }

                    AudioWaveformView(audioLevels: audioRecorder.audioLevels)
                        .transition(.opacity)

                case .processing:
                    AnimatedDotsView()
                        .transition(.opacity)

                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)

                case .error:
                    Image(systemName: "xmark")
                        .font(.system(size: Self.iconSize, weight: .semibold))
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }

                if phaseState.phase == .recording || phaseState.phase == .processing {
                    let destinationID = overrides.destinationOverride ?? settings.activeMode.defaultOutputDestinationID
                    let destination = settings.outputDestination(for: destinationID)
                    Text(buildModeLabel(
                        modeName: settings.activeMode.name,
                        parameterLabels: overrides.resolvedParameterLabels(for: settings.activeMode),
                        destinationSymbol: destination.symbol
                    ))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Self.pillHPadding)
            .frame(height: Self.pillHeight)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
            .shadow(radius: 2)

            if let message = phaseState.errorMessage, phaseState.phase == .error {
                Text(message)
                    .font(.system(size: Self.errorPillFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.errorPillHPadding)
                    .padding(.vertical, Self.errorPillVPadding)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.errorPillCornerRadius))
                    .shadow(radius: 2)
                    .transition(.opacity)
                    .onTapGesture { ClipboardHelper.writeString(message) }
            }

            if let vm = modeSwitcherState.viewModel {
                ModeSwitcherView(viewModel: vm)
                    .frame(width: ModeSwitcherPanel.panelWidth)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .animation(.default, value: phaseState.rejectCount)
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: captureState.captureCount)
    }
}

// MARK: - Audio Waveform View

/// Visualizes real microphone input as vertical bars with a symmetric
/// bell-curve shape — tallest in the center, tapering to the edges.
struct AudioWaveformView: View {
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 14
    private static let animationDuration: Double = 0.06
    /// Symmetric taper: edges are much shorter, center is tallest
    private static let barScales: [CGFloat] = [0.25, 0.6, 1.0, 0.6, 0.25]

    let audioLevels: [Float]

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(audioLevels.enumerated()), id: \.offset) { index, level in
                let scale = Self.barScales[index]
                let height = Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(level) * scale
                Capsule()
                    .fill(.red)
                    .frame(width: Self.barWidth, height: height)
            }
        }
        .animation(.easeOut(duration: Self.animationDuration), value: audioLevels)
    }
}

// MARK: - Animated Dots View

/// Three bouncing dots with staggered animation for processing state.
struct AnimatedDotsView: View {
    // MARK: - Constants

    private static let dotSize: CGFloat = 5
    private static let dotSpacing: CGFloat = 3
    private static let bounceHeight: CGFloat = 4
    private static let animationDuration: Double = 0.4
    private static let dotStaggerDelay: Double = 0.15
    private static let dotCount = 3

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .offset(y: isAnimating ? -Self.bounceHeight : 0)
                    .animation(
                        .easeInOut(duration: Self.animationDuration)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * Self.dotStaggerDelay),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
    }
}
