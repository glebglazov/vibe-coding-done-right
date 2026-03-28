import SwiftUI

// MARK: - Info Pill View

/// Reusable ephemeral pill with an SF Symbol icon and optional label text.
/// Used for dismiss, cancel, success, and other brief informational indicators.
struct InfoPillView: View {
    private static let iconSize: CGFloat = 16
    private static let spacing: CGFloat = 4

    let icon: String
    let iconColor: Color
    var label: String? = nil

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: icon)
                .font(.system(size: Self.iconSize, weight: .semibold))
                .foregroundStyle(iconColor)
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .pillShape()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Cancelled Indicator View

struct CancelledIndicatorView: View {
    var body: some View {
        InfoPillView(icon: "xmark", iconColor: .secondary)
    }
}

// MARK: - Copied Indicator View

struct CopiedIndicatorView: View {
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
            .pillShape()
            .animation(.easeInOut(duration: 0.2), value: showCheckmark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Animate from clipboard icon to checkmark after a short delay for visual feedback
            try? await Task.sleep(for: Self.transitionDelay)
            showCheckmark = true
        }
    }
}

// MARK: - Copy Error Indicator View

struct CopyErrorIndicatorView: View {
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
            .pillShape()

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
    let settings: AppSettings
    let overrides: SessionOverrides
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
            .pillShape()

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

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(ShakeEffect(shakeCount: phaseState.rejectCount))
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: phaseState.phase)
        .animation(.default, value: phaseState.rejectCount)
        .animation(.easeInOut(duration: Self.phaseTransitionDuration), value: captureState.captureCount)
    }
}
