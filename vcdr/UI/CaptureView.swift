import SwiftUI

struct CaptureView: View {
    @Bindable var viewModel: CaptureViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    static let textPadding: CGFloat = 12
    private static let hintBarHPadding: CGFloat = 10
    private static let hintBarVPadding: CGFloat = 6
    private static let hintSpacing: CGFloat = 12
    private static let keyCornerRadius: CGFloat = 3
    private static let keyHPadding: CGFloat = 4
    private static let keyVPadding: CGFloat = 1
    private static let closeButtonPadding: CGFloat = 5
    private static let headerBottomPadding: CGFloat = 2
    private static let headerBackgroundOpacity: Double = 0.03
    private static let closeButtonSize: CGFloat = 12
    private static let recordingDotSize: CGFloat = 8

    // MARK: - Constants (Pill)

    private static let pillIconSize: CGFloat = 14
    private static let pillSpacing: CGFloat = 6
    var body: some View {
        if viewModel.isMinimized {
            minimizedPillView
        } else {
            expandedView
        }
    }

    // MARK: - Minimized Pill

    private var minimizedPillView: some View {
        HStack(spacing: Self.pillSpacing) {
            switch viewModel.phase {
            case .idle:
                Image(systemName: "text.cursor")
                    .font(.system(size: Self.pillIconSize))
                    .foregroundStyle(.secondary)
            case .recording:
                AudioWaveformView(audioLevels: viewModel.audioRecorder?.audioLevels ?? [])
            case .processing:
                AnimatedDotsView()
            case .error, .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: Self.pillIconSize, weight: .semibold))
                    .foregroundStyle(.red)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: Self.pillIconSize, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Text((viewModel.phase == .error ? viewModel.errorMessage : nil) ?? viewModel.pillModeLabel)
                .font(.caption)
                .foregroundStyle(viewModel.phase == .error && viewModel.errorMessage != nil ? Color.red : Color.primary)
                .lineLimit(1)
        }
        .pillShape()
        .modifier(ShakeEffect(shakeCount: viewModel.rejectCount))
        .animation(.default, value: viewModel.rejectCount)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onTapGesture {
            if viewModel.phase == .error, let msg = viewModel.errorMessage { ClipboardHelper.writeString(msg) }
            viewModel.onExpand()
        }
    }

    // MARK: - Expanded View

    private var expandedView: some View {
        VStack(spacing: 0) {
            headerBar

            if viewModel.displayedTurn != nil {
                displayedTurnSection
            }

            Divider()

            hintBar
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack {
                if viewModel.isRecording {
                    recordingDot
                }
                Spacer()
                Button(action: viewModel.onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Self.closeButtonSize))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Self.closeButtonPadding)
            .padding(.top, Self.closeButtonPadding)
            .padding(.bottom, Self.headerBottomPadding)

            Divider()
            if viewModel.phase == .error, let errorMessage = viewModel.errorMessage {
                ErrorBannerView(message: errorMessage, onDismiss: { viewModel.clearError() })
                Divider()
            }
        }
        .background(Color.primary.opacity(Self.headerBackgroundOpacity))
    }

    private var recordingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: Self.recordingDotSize, height: Self.recordingDotSize)
            .shadow(color: .red.opacity(0.6), radius: 4)
            .shadow(color: .red.opacity(0.3), radius: 8)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack(spacing: Self.hintSpacing) {
            Text(viewModel.modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.outputDestinations.filter { $0.activationHotkey.isAssigned }) { dest in
                hintLabel(dest.activationHotkey.displayString, viewModel.destinationDisplayName(for: dest))
            }

            Spacer()
            if !viewModel.isRecording {
                hintLabel("\u{21B5}", viewModel.displayedTurn != nil ? "confirm" : "submit")
            }
            hintLabel("esc", "dismiss")
        }
        .padding(.horizontal, Self.hintBarHPadding)
        .padding(.vertical, Self.hintBarVPadding)
    }

    private func hintLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, Self.keyHPadding)
                .padding(.vertical, Self.keyVPadding)
                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: Self.keyCornerRadius))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
