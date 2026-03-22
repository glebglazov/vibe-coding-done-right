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
    private static let segmentTextMinHeight: CGFloat = 28
    private static let minEditorHeight: CGFloat = 28
    private static let textInputTopInset: CGFloat = 4
    private static let recordingDotSize: CGFloat = 8

    // MARK: - Constants (Pill)

    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillIconSize: CGFloat = 14
    private static let pillSpacing: CGFloat = 6
    private static let captureBadgeSize: CGFloat = 12
    private static let captureCountFontSize: CGFloat = 9

    /// Per-segment focus trigger counters. Bumped to shift focus to a specific editor
    /// when the user arrows past the boundary of the current editor.
    @State private var focusTriggers: [UUID: Int] = [:]
    /// Exact character offset for cursor placement when focus is requested.
    /// Arrow-up from below uses Int.max (clamped to end), arrow-down from above uses 0.
    @State private var focusCursorPosition: [UUID: Int] = [:]

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

            Text((viewModel.phase == .error ? viewModel.errorMessage : nil) ?? viewModel.pillModeLabel)
                .font(.caption)
                .foregroundStyle(viewModel.phase == .error && viewModel.errorMessage != nil ? Color.red : Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, Self.pillHPadding)
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
        .shadow(radius: 2)
        .modifier(ShakeEffect(shakeCount: viewModel.rejectCount))
        .animation(.default, value: viewModel.rejectCount)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onTapGesture {
            if viewModel.phase == .error, let msg = viewModel.errorMessage { ClipboardHelper.writeString(msg) }
            viewModel.onExpand()
        }
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

                segmentedInputSection
            }

            Divider()

            hintBar
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    .onChange(of: viewModel.focusRequest, initial: true) { _, newValue in
        guard newValue > 0 else { return }
        let index = viewModel.activeSegmentIndex
        guard index < viewModel.inputSegments.count else { return }
        let segment = viewModel.inputSegments[index]
        // Use saved cursor position if available (e.g., after dictation insertion),
        // otherwise place cursor at end (e.g., first dictation, expand from pill).
        focusCursorPosition[segment.id] = viewModel.savedCursorPositions[segment.id]
            ?? (segment.text as NSString).length
        focusTriggers[segment.id, default: 0] += 1
    }
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

    // MARK: - Input Section

    @ViewBuilder
    private var segmentedInputSection: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder overlay
            if viewModel.fullText.isEmpty && !viewModel.isRecording && !viewModel.isProcessing
                && !viewModel.conversationTurns.isEmpty {
                Text("Type a follow-up...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.textPadding)
                    .padding(.top, 8 + Self.textInputTopInset)
                    .allowsHitTesting(false)
            }
            if viewModel.fullText.isEmpty && viewModel.isProcessing
                && viewModel.conversationTurns.isEmpty {
                AnimatedDotsView()
                    .padding(.horizontal, Self.textPadding)
                    .padding(.top, 8 + Self.textInputTopInset)
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.inputSegments.enumerated()), id: \.element.id) { index, segment in
                    SegmentEditor(
                        text: segmentTextBinding(at: index),
                        isEditable: !viewModel.isProcessing,
                        focusTrigger: focusTriggers[segment.id, default: 0],
                        focusCursorPosition: focusCursorPosition[segment.id, default: 0],
                        initialCursorPosition: viewModel.savedCursorPositions[segment.id],
                        onFocus: { cursorPosition in
                            viewModel.activeSegmentIndex = index
                            viewModel.savedCursorPositions[segment.id] = cursorPosition
                        },
                        onMoveUp: index > 0 ? {
                            let target = viewModel.inputSegments[index - 1]
                            focusCursorPosition[target.id] = Int.max
                            focusTriggers[target.id, default: 0] += 1
                        } : nil,
                        onMoveDown: {
                            if index < viewModel.inputSegments.count - 1 {
                                // Focus the next existing editor
                                let target = viewModel.inputSegments[index + 1]
                                focusCursorPosition[target.id] = 0
                                focusTriggers[target.id, default: 0] += 1
                            } else if segment.capture != nil {
                                // Last segment has a capture below — create a new
                                // empty segment so the user can type after it.
                                let newSegment = InputSegment()
                                viewModel.inputSegments.append(newSegment)
                                viewModel.activeSegmentIndex = viewModel.inputSegments.count - 1
                                focusCursorPosition[newSegment.id] = 0
                                // Defer focus request — the new SegmentEditor's NSTextView
                                // must be in the window hierarchy before makeFirstResponder
                                // works. Bumping the trigger in a Task lets SwiftUI complete
                                // the layout pass first.
                                Task { @MainActor in
                                    focusTriggers[newSegment.id, default: 0] += 1
                                }
                            }
                        },
                        onHeightChange: { height in
                            viewModel.segmentHeights[segment.id] = height
                            viewModel.onContentHeightChanged?()
                        }
                    )
                    .frame(height: max(Self.minEditorHeight, viewModel.segmentHeights[segment.id] ?? Self.minEditorHeight))

                    if let capture = segment.capture {
                        captureBlockquote(capture)
                            .padding(.horizontal, Self.textPadding)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(minHeight: Self.segmentTextMinHeight)
    }

    // MARK: - Segment Helpers

    private func segmentTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { viewModel.inputSegments.indices.contains(index) ? viewModel.inputSegments[index].text : "" },
            set: { newValue in
                guard viewModel.inputSegments.indices.contains(index) else { return }
                viewModel.inputSegments[index].text = newValue
            }
        )
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
