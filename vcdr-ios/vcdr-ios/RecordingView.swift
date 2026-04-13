import SwiftUI

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme.current(for: colorScheme) }
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var showCopiedConfirmation = false
    @State private var showSettings = false
    @State private var recordingStart: Date?

    // MARK: - Constants
    private static let copiedConfirmationDuration: Duration = .seconds(3)
    private static let actionButtonSize: CGFloat = 96
    private static let actionButtonBorder: CGFloat = 8
    private static let stopIconSize: CGFloat = 32
    private static let recordIconSize: CGFloat = 36
    private static let dotGridSpacing: CGFloat = 40
    private static let dotGridRadius: CGFloat = 0.5
    private static let transcriptFontSize: CGFloat = 18
    private static let transcriptMaxHeight: CGFloat = 200
    private static let hintFontSize: CGFloat = 13
    private static let returnPulseDuration: Double = 0.8
    private static let aiPillHeight: CGFloat = 32

    var body: some View {
        ZStack {
            theme.surfaceLowest.ignoresSafeArea()
            dotGrid

            VStack(spacing: 0) {
                topBar
                stateContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomArea
            }
        }
        .onChange(of: coordinator.state) { _, newState in
            if case .recording = newState {
                recordingStart = .now
            } else {
                recordingStart = nil
            }
        }
        // Propagate theme to child views (WaveformView) via environment
        .environment(\.theme, theme)
    }

    // MARK: - Top Bar

    @ViewBuilder
    private var topBar: some View {
        if case .recording = coordinator.state {
            EmptyView()
        } else {
            HStack {
                Spacer()
                settingsButton
                    .padding(.trailing, 20)
                    .padding(.top, 12)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
                .environment(\.theme, theme)
        }
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch coordinator.state {
        case .idle, .initializing:
            initializingContent

        case .ready:
            readyContent

        case .recording:
            recordingContent

        case .transcribing:
            transcribingContent

        case .complete(let text):
            completeContent(text)

        case .error(let message):
            errorContent(message)
        }
    }

    private var initializingContent: some View {
        VStack(spacing: 40) {
            VStack(spacing: 24) {
                heroTitle("PREPARING")
                ProgressView()
                    .tint(theme.primary)
                    .scaleEffect(1.2)
                Text(coordinator.initProgress.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            actionCircle(
                icon: { Circle().fill(theme.onSurface).frame(width: Self.recordIconSize, height: Self.recordIconSize) },
                label: "RECORD"
            ) {
                Task { await coordinator.startRecording() }
            }
        }
    }

    private var readyContent: some View {
        VStack(spacing: 40) {
            heroTitle("READY")
            actionCircle(
                icon: { Circle().fill(theme.onSurface).frame(width: Self.recordIconSize, height: Self.recordIconSize) },
                label: "RECORD"
            ) {
                Task { await coordinator.startRecording() }
            }
        }
    }

    private var recordingContent: some View {
        ZStack {
            // Core content — truly centered on screen
            VStack(spacing: 0) {
                heroTitle("LISTENING")
                    .padding(.bottom, 8)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = recordingStart.map { context.date.timeIntervalSince($0) } ?? 0
                    Text(formatDuration(elapsed))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(theme.primary.opacity(0.8))
                }
                .padding(.bottom, 32)

                // Waveform with transcript overlay
                ZStack {
                    WaveformView(levels: coordinator.audioLevels)
                        .frame(height: 120)
                        .padding(.horizontal, 8)

                    if !coordinator.liveTranscript.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(coordinator.liveTranscript)
                                    .font(.system(size: Self.transcriptFontSize, weight: .light))
                                    .foregroundStyle(theme.onSurface.opacity(0.7))
                                    .lineSpacing(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 32)
                                    .id("transcript")
                            }
                            .onChange(of: coordinator.liveTranscript) {
                                withAnimation {
                                    proxy.scrollTo("transcript", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .frame(height: 120)

                aiSessionToggle
                    .padding(.top, 20)
            }

            // Top overlay — return hint
            VStack {
                HStack {
                    if coordinator.launchedViaDeepLink {
                        returnHint
                            .padding(.leading, 20)
                    }
                    Spacer()
                }
                .padding(.top, 16)
                Spacer()
            }

            // Bottom-pinned content — stop button
            VStack(spacing: 0) {
                Spacer()

                actionCircle(
                    icon: {
                        Rectangle()
                            .fill(theme.onSurface)
                            .frame(width: Self.stopIconSize, height: Self.stopIconSize)
                    },
                    label: "STOP"
                ) {
                    Task { await coordinator.stopAndTranscribe(sendToKeyboard: false) }
                }
                .padding(.bottom, 16)

                if coordinator.launchedViaDeepLink {
                    swipeBackHint
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private var returnHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: Self.hintFontSize, weight: .semibold))
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 1 : 0.3)
                } animation: { _ in
                    .easeInOut(duration: Self.returnPulseDuration)
                }
            Text("Press to go back")
                .font(.system(size: Self.hintFontSize, weight: .medium))
        }
        .foregroundStyle(theme.onSurfaceVariant)
    }

    private var swipeBackHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left")
                .font(.system(size: Self.hintFontSize, weight: .semibold))
                .phaseAnimator([false, true]) { content, phase in
                    content
                        .offset(x: phase ? 8 : -4)
                        .opacity(phase ? 0.3 : 1)
                } animation: { _ in
                    .easeInOut(duration: Self.returnPulseDuration)
                }
            Text("Swipe to go back")
                .font(.system(size: Self.hintFontSize, weight: .medium))
        }
        .foregroundStyle(theme.onSurfaceVariant)
    }

    private var transcribingContent: some View {
        VStack(spacing: 24) {
            heroTitle("PROCESSING")
            ProgressView()
                .tint(theme.primary)
                .scaleEffect(1.2)
            if !coordinator.transcribingMessage.isEmpty {
                Text(coordinator.transcribingMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func completeContent(_ text: String) -> some View {
        VStack(spacing: 28) {
            heroTitle("DONE")

            aiStatusView

            HStack(spacing: 16) {
                brutalistButton(showCopiedConfirmation ? "COPIED" : "COPY") {
                    UIPasteboard.general.string = text
                    showCopiedConfirmation = true
                    Task {
                        try? await Task.sleep(for: Self.copiedConfirmationDuration)
                        showCopiedConfirmation = false
                    }
                }
                brutalistButton("NEW") {
                    Task { await coordinator.startRecording() }
                }
            }

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    Rectangle()
                        .fill(theme.primary)
                        .frame(width: 2)
                    Text(text)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(theme.onSurface)
                        .lineSpacing(6)
                }
            }
            .frame(maxHeight: 200)
            .padding(.horizontal, 32)
        }
    }

    @ViewBuilder
    private var aiStatusView: some View {
        if !coordinator.aiActiveThisSession || coordinator.aiProcessingStatus == .idle {
            EmptyView()
        } else if coordinator.aiProcessingStatus == .processing {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(theme.onSurfaceVariant)
                    .scaleEffect(0.8)
                Text("AI PROCESSING")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        } else if coordinator.aiProcessingStatus == .timedOut {
            VStack(spacing: 8) {
                Text("AI UNAVAILABLE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.onSurfaceVariant)
                brutalistButton("RETRY") {
                    coordinator.retryAIProcessing()
                }
            }
        } else if coordinator.aiProcessingStatus == .completed {
            Text("ENHANCED BY AI")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.primary)
        } else if case .error(let message) = coordinator.aiProcessingStatus {
            VStack(spacing: 8) {
                Text(message.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                brutalistButton("RETRY") {
                    coordinator.retryAIProcessing()
                }
            }
        }
    }

    @ViewBuilder
    private var aiSessionToggle: some View {
        HStack(spacing: 8) {
            // AI toggle pill (only show if AI is configured)
            if AIProcessingSettings.isConfigured {
                Button {
                    coordinator.aiActiveThisSession.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text(coordinator.aiActiveThisSession ? "AI ON" : "AI OFF")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2)
                    }
                    .foregroundStyle(coordinator.aiActiveThisSession ? theme.primary : theme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .frame(height: Self.aiPillHeight)
                    .background(theme.surfaceHigh)
                }

                if coordinator.aiActiveThisSession {
                    Button {
                        coordinator.selectedPromptMode = coordinator.selectedPromptMode.next
                    } label: {
                        Text(coordinator.selectedPromptMode.displayName.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(theme.primary)
                            .padding(.horizontal, 12)
                            .frame(height: Self.aiPillHeight)
                            .background(theme.surfaceHigh)
                    }
                }
            }

            // Style toggle pill
            Button {
                coordinator.currentTextStyle = coordinator.currentTextStyle == .casual ? .formal : .casual
            } label: {
                Text(coordinator.currentTextStyle.displayName.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 16)
                    .frame(height: Self.aiPillHeight)
                    .background(theme.surfaceHigh)
            }
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 24) {
            heroTitle("ERROR")
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            brutalistButton("TRY AGAIN") { coordinator.reset() }
        }
    }

    // MARK: - Bottom Area

    @ViewBuilder
    private var bottomArea: some View {
        EmptyView()
    }

    // MARK: - Reusable Components

    private func heroTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 64, weight: .black))
            .tracking(-2)
            .foregroundStyle(theme.onSurface)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }

    private func actionCircle<Icon: View>(
        icon: () -> Icon,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(theme.primaryDim)
                        .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                        .shadow(color: theme.primaryDim.opacity(0.2), radius: 20)
                    Circle()
                        .stroke(theme.surfaceHighest, lineWidth: Self.actionButtonBorder)
                        .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                    icon()
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.onSurface)
        }
    }

    private func brutalistButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(theme.surfaceHigh)
        }
    }

    // MARK: - Background

    private var dotGrid: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(0), through: size.width, by: Self.dotGridSpacing) {
                for y in stride(from: CGFloat(0), through: size.height, by: Self.dotGridSpacing) {
                    let rect = CGRect(
                        x: x - Self.dotGridRadius,
                        y: y - Self.dotGridRadius,
                        width: Self.dotGridRadius * 2,
                        height: Self.dotGridRadius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(theme.dotGridColor))
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
