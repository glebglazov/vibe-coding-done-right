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
    private static let captureBadgeSize: CGFloat = 12
    private static let captureCountFontSize: CGFloat = 9
    private static let cursorContextIconSize: CGFloat = 10
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
            // Cursor context indicator (left-most)
            cursorContextIndicator

            switch viewModel.phaseState.phase {
            case .idle:
                Image(systemName: "text.cursor")
                    .font(.system(size: Self.pillIconSize))
                    .foregroundStyle(.secondary)
            case .recording:
                captureBadge
                AudioWaveformView(audioLevels: viewModel.audioRecorder?.audioLevels ?? [])
            case .processing:
                captureBadge
                AnimatedDotsView()
            case .error:
                Image(systemName: "xmark")
                    .font(.system(size: Self.pillIconSize, weight: .semibold))
                    .foregroundStyle(.red)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: Self.pillIconSize, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Text(viewModel.pillLabel)
                .font(.caption)
                .foregroundStyle(viewModel.phaseState.phase == .error && viewModel.phaseState.errorMessage != nil ? Color.red : Color.primary)
                .lineLimit(1)
        }
        .pillShape()
        .modifier(ShakeEffect(shakeCount: viewModel.feedbackCounters.rejectCount))
        .animation(.default, value: viewModel.feedbackCounters.rejectCount)
        .animation(.easeInOut(duration: 0.2), value: viewModel.feedbackCounters.clipboardCaptureCount)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onTapGesture {
            viewModel.onPillTapped()
        }
    }

    /// Shows whether cursor context capture is available for the current app.
    /// Green checkmark = context capture available; Gray slash = not available.
    @ViewBuilder
    private var cursorContextIndicator: some View {
        if viewModel.phaseState.phase == .recording {
            Image(systemName: viewModel.cursorContextAvailable ? "checkmark.circle.fill" : "slash.circle")
                .font(.system(size: Self.cursorContextIconSize))
                .foregroundStyle(viewModel.cursorContextAvailable ? .green : .secondary)
                .help(cursorContextTooltip)
        }
    }

    private var cursorContextTooltip: String {
        if viewModel.cursorContextAvailable {
            return "Cursor context capture is active. The app will use surrounding text for smart formatting."
        } else {
            return "Cursor context capture is unavailable for this app. Smart formatting will use default behavior."
        }
    }

    @ViewBuilder
    private var captureBadge: some View {
        if viewModel.feedbackCounters.clipboardCaptureCount > 0 {
            HStack(spacing: 1) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: Self.captureBadgeSize, weight: .medium))
                    .foregroundStyle(.secondary)
                if viewModel.feedbackCounters.clipboardCaptureCount > 1 {
                    Text("×\(viewModel.feedbackCounters.clipboardCaptureCount)")
                        .font(.system(size: Self.captureCountFontSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
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
            if viewModel.phaseState.phase == .error, let errorMessage = viewModel.phaseState.errorMessage {
                ErrorBannerView(message: errorMessage, onDismiss: { viewModel.clearError() })
                Divider()
            }
            if let aiError = viewModel.aiProcessingErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let retry = viewModel.onRetryAIProcessing {
                        Button("Retry") { retry() }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, Self.closeButtonPadding)
                .padding(.vertical, 6)
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
