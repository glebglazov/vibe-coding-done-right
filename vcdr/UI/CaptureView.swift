import SwiftUI

struct CaptureView: View {
    @Bindable var viewModel: CaptureViewModel

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 10
    private static let textPadding: CGFloat = 12
    private static let hintBarHPadding: CGFloat = 10
    private static let hintBarVPadding: CGFloat = 6
    private static let hintSpacing: CGFloat = 12
    private static let keyCornerRadius: CGFloat = 3
    private static let keyHPadding: CGFloat = 4
    private static let keyVPadding: CGFloat = 1
    private static let labelVPadding: CGFloat = 4
    private static let turnDividerVPadding: CGFloat = 4
    private static let closeButtonPadding: CGFloat = 5
    private static let headerBottomPadding: CGFloat = 2
    private static let headerBackgroundOpacity: Double = 0.03
    private static let closeButtonSize: CGFloat = 12
    private static let copyButtonSize: CGFloat = 12
    private static let blockquoteBorderWidth: CGFloat = 2
    private static let blockquoteBorderSpacing: CGFloat = 6
    private static let blockquoteBorderOpacity: Double = 0.4
    private static let blockquoteLeadingPadding: CGFloat = 4
    private static let textInputHeight: CGFloat = 60
    private static let textInputTopInset: CGFloat = 4
    private static let recordingDotSize: CGFloat = 8

    // MARK: - Constants (Pill)

    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillIconSize: CGFloat = 14
    private static let pillSpacing: CGFloat = 6
    private static let captureBadgeSize: CGFloat = 12
    private static let captureCountFontSize: CGFloat = 9

    /// ID for the bottom anchor used to auto-scroll
    private static let bottomAnchorID = "bottom"

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
            if viewModel.clipboardCaptureCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: Self.captureBadgeSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    if viewModel.clipboardCaptureCount > 1 {
                        Text("\u{00D7}\(viewModel.clipboardCaptureCount)")
                            .font(.system(size: Self.captureCountFontSize, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }

            switch viewModel.phase {
            case .idle:
                Image(systemName: viewModel.conversationTurns.isEmpty ? "text.cursor" : "text.bubble")
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

            Text(viewModel.pillModeLabel)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, Self.pillHPadding)
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
        .shadow(radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onTapGesture { viewModel.onExpand() }
        .animation(.easeInOut(duration: 0.2), value: viewModel.clipboardCaptureCount)
    }

    // MARK: - Expanded View

    private var expandedView: some View {
        VStack(spacing: 0) {
            headerBar

            if let msVM = viewModel.modeSwitcherViewModel {
                ModeSwitcherView(viewModel: msVM)
                    .padding(Self.textPadding)
            } else {
                if !viewModel.conversationTurns.isEmpty {
                    conversationHistorySection
                }

                if !viewModel.conversationTurns.isEmpty {
                    Divider()
                }

                inputSection

                if !viewModel.captures.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.captures) { capture in
                            captureBlockquote(capture)
                        }
                    }
                    .padding(Self.textPadding)
                }
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
        }
        .background(Color.primary.opacity(Self.headerBackgroundOpacity))
    }

    // MARK: - Input Section

    @ViewBuilder
    private var inputSection: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.text.isEmpty && !viewModel.isRecording && !viewModel.isProcessing && !viewModel.conversationTurns.isEmpty {
                Text("Type a follow-up...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.textPadding)
                    .padding(.top, 8 + Self.textInputTopInset)
                    .allowsHitTesting(false)
            }
            if viewModel.text.isEmpty && viewModel.isProcessing && viewModel.conversationTurns.isEmpty {
                AnimatedDotsView()
                    .padding(.horizontal, Self.textPadding)
                    .padding(.top, 8 + Self.textInputTopInset)
            }
            TextEditor(text: $viewModel.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .disabled(viewModel.isRecording || viewModel.isProcessing)
                .padding(.horizontal, Self.textPadding - 5)
                .padding(.top, Self.textInputTopInset)
        }
        .frame(height: Self.textInputHeight)
    }

    private var recordingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: Self.recordingDotSize, height: Self.recordingDotSize)
            .shadow(color: .red.opacity(0.6), radius: 4)
            .shadow(color: .red.opacity(0.3), radius: 8)
    }

    // MARK: - Conversation History

    private var conversationHistorySection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.conversationTurns.enumerated()), id: \.element.id) { index, turn in
                        let isProcessingTurn = viewModel.isProcessing && index == viewModel.conversationTurns.count - 1
                        turnView(turn, showLabels: viewModel.showConversationLabels, isProcessingTurn: isProcessingTurn)

                        if index < viewModel.conversationTurns.count - 1 {
                            Divider()
                                .padding(.vertical, Self.turnDividerVPadding)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(Self.textPadding)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: viewModel.scrollTrigger) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ConversationTurn, showLabels: Bool, isProcessingTurn: Bool = false) -> some View {
        if showLabels {
            Text("You:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, Self.labelVPadding)

            Text(turn.input)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Self.labelVPadding)

            ForEach(turn.captures) { capture in
                captureBlockquote(capture)
                    .padding(.bottom, Self.labelVPadding)
            }

            HStack {
                if !isProcessingTurn {
                    copyButton(for: turn.output)
                }
                Text("Result:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let modeName = viewModel.processedByModeName {
                    Text(modeName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            .padding(.bottom, Self.labelVPadding)
        }

        if isProcessingTurn && (turn.output.isEmpty || turn.output == "...") {
            AnimatedDotsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(turn.output)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Capture Blockquote

    private func captureBlockquote(_ capture: CapturedContext) -> some View {
        HStack(alignment: .top, spacing: Self.blockquoteBorderSpacing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(Self.blockquoteBorderOpacity))
                .frame(width: Self.blockquoteBorderWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(capture.text)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Self.blockquoteLeadingPadding)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack(spacing: Self.hintSpacing) {
            Text(viewModel.modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.outputDestinations.filter { $0.activationHotkey.isAssigned }) { dest in
                hintLabel(
                    GlobalHotkeyManager.shortcutDisplayString(
                        keyCode: CGKeyCode(dest.activationHotkey.keyCode),
                        modifiers: CGEventFlags(rawValue: dest.activationHotkey.modifiers)
                    ),
                    dest.name.lowercased()
                )
            }

            Spacer()
            if !viewModel.isRecording {
                hintLabel("\u{21B5}", "submit")
            }
            hintLabel("esc", "dismiss")
        }
        .padding(.horizontal, Self.hintBarHPadding)
        .padding(.vertical, Self.hintBarVPadding)
    }

    // MARK: - Helpers

    private func copyButton(for text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: Self.copyButtonSize))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
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
