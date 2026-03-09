import SwiftUI

// MARK: - View Model

@Observable
final class OutputPanelViewModel {
    /// Pill phase controls what the minimized pill displays
    enum OutputPillPhase {
        case idle        // conversation icon (text.bubble)
        case recording   // audio waveform
        case processing  // animated bouncing dots
    }

    var conversationTurns: [ConversationTurn]
    let outputDestinations: [OutputDestination]
    let isReadOnly: Bool
    let onCopy: () -> Void
    let onFireDestination: (OutputDestination) -> Void
    let onDismiss: () -> Void
    let onSubmitText: (String) -> Void
    let onExpand: () -> Void
    let audioRecorder: AudioRecorder?

    var inlineText: String = ""
    var isProcessing: Bool = false
    /// Incremented to trigger scroll-to-bottom in the conversation ScrollView
    var scrollTrigger: Int = 0
    var isMinimized: Bool = false
    var pillPhase: OutputPillPhase = .idle

    /// Show "You:" / "Result:" labels when there are multiple turns or
    /// when the single turn's input was transformed by processing.
    /// Captured selection alone only triggers labels when follow-up is enabled,
    /// so non-conversation modes show plain output even with selected text.
    var showConversationLabels: Bool {
        if conversationTurns.count > 1 { return true }
        if isReadOnly { return false }
        guard let turn = conversationTurns.first else { return false }
        if turn.capturedSelection != nil { return true }
        return turn.input != turn.output
    }

    /// Latest output text for copy/fire actions
    var latestText: String {
        conversationTurns.last?.output ?? ""
    }

    init(
        conversationTurns: [ConversationTurn],
        outputDestinations: [OutputDestination],
        isReadOnly: Bool = false,
        onCopy: @escaping () -> Void,
        onFireDestination: @escaping (OutputDestination) -> Void,
        onDismiss: @escaping () -> Void,
        onSubmitText: @escaping (String) -> Void,
        onExpand: @escaping () -> Void = {},
        audioRecorder: AudioRecorder? = nil
    ) {
        self.conversationTurns = conversationTurns
        self.outputDestinations = outputDestinations
        self.isReadOnly = isReadOnly
        self.onCopy = onCopy
        self.onFireDestination = onFireDestination
        self.onDismiss = onDismiss
        self.onSubmitText = onSubmitText
        self.onExpand = onExpand
        self.audioRecorder = audioRecorder
    }

    /// Returns true if the event was handled (consumed)
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let hasCmd = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 36: // Return
            guard !isReadOnly else { return true }
            // Shift+Return inserts newline (pass through to text editor)
            if event.modifierFlags.contains(.shift) { return false }
            guard !isProcessing else { return true }
            let trimmed = inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            onSubmitText(trimmed)
            return true
        case 53: // Escape
            onDismiss()
            return true
        default:
            guard hasCmd else { return false }

            if chars == "c" {
                onCopy()
                onDismiss()
                return true
            }
            // Check destination activation keys (Cmd + key) — always available
            if let char = chars.first {
                let key = String(char)
                if let destination = outputDestinations.first(where: { $0.activationKey == key }) {
                    onFireDestination(destination)
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - SwiftUI View

struct OutputPanelView: View {
    @Bindable var viewModel: OutputPanelViewModel

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
    private static let closeButtonPadding: CGFloat = 8
    private static let closeButtonSize: CGFloat = 16
    private static let copyButtonSize: CGFloat = 12
    private static let blockquoteBorderWidth: CGFloat = 2
    private static let blockquoteBorderSpacing: CGFloat = 6
    private static let blockquoteBorderOpacity: Double = 0.4
    private static let blockquoteLeadingPadding: CGFloat = 4

    /// ID for the bottom anchor used to auto-scroll
    private static let bottomAnchorID = "bottom"
    private static let textInputHeight: CGFloat = 60

    // Minimized pill constants
    private static let pillHeight: CGFloat = 32
    private static let pillHPadding: CGFloat = 12
    private static let pillIconSize: CGFloat = 12
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
            switch viewModel.pillPhase {
            case .idle:
                Image(systemName: "text.bubble")
                    .font(.system(size: Self.pillIconSize))
                    .foregroundStyle(.secondary)
            case .recording:
                AudioWaveformView(audioLevels: viewModel.audioRecorder?.audioLevels ?? [])
            case .processing:
                AnimatedDotsView()
            }
        }
        .padding(.horizontal, Self.pillHPadding)
        .frame(height: Self.pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
        .shadow(radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onTapGesture { viewModel.onExpand() }
    }

    // MARK: - Expanded View

    private var expandedView: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
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

                            // Invisible anchor for scrolling to bottom
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

                if !viewModel.isReadOnly {
                    Divider()

                    ZStack(alignment: .topLeading) {
                        if viewModel.inlineText.isEmpty && !viewModel.isProcessing {
                            Text("Type a follow-up...")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Self.textPadding)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $viewModel.inlineText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .disabled(viewModel.isProcessing)
                            .padding(.horizontal, Self.textPadding - 5)
                    }
                    .frame(height: Self.textInputHeight)
                }

                Divider()

                HStack(spacing: Self.hintSpacing) {
                    hintLabel("\u{2318}C", "copy")
                    ForEach(viewModel.outputDestinations.filter { !$0.activationKey.isEmpty }) { dest in
                        hintLabel("\u{2318}\(dest.activationKey.uppercased())", dest.name.lowercased())
                    }
                    Spacer()
                    if !viewModel.isReadOnly {
                        hintLabel("\u{21B5}", "submit")
                    }
                }
                .padding(.horizontal, Self.hintBarHPadding)
                .padding(.vertical, Self.hintBarVPadding)
            }

            Button(action: viewModel.onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Self.closeButtonSize))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(Self.closeButtonPadding)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
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

            // Captured selection blockquote
            if let selection = turn.capturedSelection {
                selectionBlockquote(selection)
                    .padding(.bottom, Self.labelVPadding)
            }

            HStack {
                Text("Result:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !isProcessingTurn {
                    copyButton(for: turn.output)
                }
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

    private func selectionBlockquote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Self.blockquoteBorderSpacing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(Self.blockquoteBorderOpacity))
                .frame(width: Self.blockquoteBorderWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("Context:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(text)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Self.blockquoteLeadingPadding)
    }

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
