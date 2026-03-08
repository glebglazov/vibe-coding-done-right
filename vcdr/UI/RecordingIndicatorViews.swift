import SwiftUI

// MARK: - Cancelled Indicator View

struct CancelledIndicatorView: View {
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let iconSize: CGFloat = 16

    var body: some View {
        VStack {
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
        }
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
