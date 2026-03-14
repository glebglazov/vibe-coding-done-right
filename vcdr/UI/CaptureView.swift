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
    private static let segmentTextMinHeight: CGFloat = 60
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

    /// Per-segment focus trigger counters. Bumped to shift focus to a specific editor
    /// when the user arrows past the boundary of the current editor.
    @State private var focusTriggers: [UUID: Int] = [:]
    /// Whether the focus request should place the cursor at end (arrow-up from below)
    /// vs start (arrow-down from above).
    @State private var focusCursorAtEnd: [UUID: Bool] = [:]

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

                segmentedInputSection
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

    /// Height per line of editor text, matching CapturePanel.lineHeight for consistent sizing.
    private static let editorLineHeight: CGFloat = 20
    /// Vertical padding from NSTextView textContainerInset (top + bottom).
    private static let editorVerticalPadding: CGFloat = 8

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
                ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                    SegmentEditor(
                        text: segmentTextBinding(at: index),
                        isEditable: !viewModel.isProcessing,
                        focusTrigger: focusTriggers[segment.id, default: 0],
                        focusCursorAtEnd: focusCursorAtEnd[segment.id, default: false],
                        initialCursorPosition: viewModel.savedCursorPositions[segment.id],
                        onFocus: { cursorPosition in
                            viewModel.activeSegmentIndex = index
                            viewModel.savedCursorPositions[segment.id] = cursorPosition
                        },
                        onMoveUp: index > 0 ? {
                            let target = viewModel.segments[index - 1]
                            focusCursorAtEnd[target.id] = true
                            focusTriggers[target.id, default: 0] += 1
                        } : nil,
                        onMoveDown: {
                            if index < viewModel.segments.count - 1 {
                                // Focus the next existing editor
                                let target = viewModel.segments[index + 1]
                                focusCursorAtEnd[target.id] = false
                                focusTriggers[target.id, default: 0] += 1
                            } else if segment.capture != nil {
                                // Last segment has a capture below — create a new
                                // empty segment so the user can type after it.
                                let newSegment = InputSegment()
                                viewModel.segments.append(newSegment)
                                viewModel.activeSegmentIndex = viewModel.segments.count - 1
                                focusCursorAtEnd[newSegment.id] = false
                                // Defer focus request — the new SegmentEditor's NSTextView
                                // must be in the window hierarchy before makeFirstResponder
                                // works. Bumping the trigger in a Task lets SwiftUI complete
                                // the layout pass first.
                                Task { @MainActor in
                                    focusTriggers[newSegment.id, default: 0] += 1
                                }
                            }
                        }
                    )
                    .frame(height: editorHeight(for: segment.text))

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

    private func editorHeight(for text: String) -> CGFloat {
        let lines = max(1, CGFloat(text.components(separatedBy: .newlines).count))
        return lines * Self.editorLineHeight + Self.editorVerticalPadding
    }

    private func segmentTextBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { viewModel.segments.indices.contains(index) ? viewModel.segments[index].text : "" },
            set: { newValue in
                guard viewModel.segments.indices.contains(index) else { return }
                viewModel.segments[index].text = newValue
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

            turnInputView(turn)
                .padding(.bottom, Self.labelVPadding)

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

    // MARK: - Turn Input (interleaved text + blockquotes)

    /// Renders the turn's input text interleaved with capture blockquotes.
    /// Parses `<capture-N>...</capture-N>` tags from `resolveSubmissionText()` and
    /// displays the text parts as monospaced body and captures as blockquotes.
    @ViewBuilder
    private func turnInputView(_ turn: ConversationTurn) -> some View {
        let parts = parseTurnInput(turn.input, captures: turn.captures)
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .text(let value):
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .capture(let context):
                captureBlockquote(context)
            }
        }
    }

    private enum TurnInputPart {
        case text(String)
        case capture(CapturedContext)
    }

    /// Splits input text on `<capture-N>...</capture-N>` boundaries, pairing each
    /// tag with the corresponding `CapturedContext` from the turn.
    private func parseTurnInput(_ input: String, captures: [CapturedContext]) -> [TurnInputPart] {
        guard !captures.isEmpty else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }

        var parts: [TurnInputPart] = []
        var remaining = input
        var captureIndex = 0

        while captureIndex < captures.count {
            let tag = "<capture-\(captureIndex + 1)>"
            let endTag = "</capture-\(captureIndex + 1)>"

            if let tagRange = remaining.range(of: tag) {
                let before = String(remaining[remaining.startIndex..<tagRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    parts.append(.text(before))
                }
                parts.append(.capture(captures[captureIndex]))

                if let endRange = remaining.range(of: endTag) {
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    remaining = ""
                }
            } else {
                // Tag not found — append capture from the model directly
                parts.append(.capture(captures[captureIndex]))
            }
            captureIndex += 1
        }

        let trailing = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            parts.append(.text(trailing))
        }

        return parts
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
