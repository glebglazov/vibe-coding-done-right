import SwiftUI
import UIKit
import OSLog

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme.current(for: colorScheme) }
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var showCopiedConfirmation = false
    @State private var showSettings = false
    @State private var showHistory = false
    #if DEBUG
    @State private var showDebugLogs = false
    #endif
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
    private static let aiPillHeight: CGFloat = 36
    private static let pillBorder: CGFloat = 1.5
    private static let pillFontSize: CGFloat = 12

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
            HStack(spacing: 0) {
                Spacer()
                #if DEBUG
                debugLogsButton
                #endif
                historyButton
                settingsButton
            }
            .padding(.trailing, 12)
            .padding(.top, 12)
        }
    }

    #if DEBUG
    private var debugLogsButton: some View {
        Button {
            showDebugLogs = true
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .sheet(isPresented: $showDebugLogs) {
            NavigationStack {
                DebugLogView()
            }
            .preferredColorScheme(appearance.colorScheme)
        }
        .accessibilityLabel("Debug Logs")
    }
    #endif

    private var historyButton: some View {
        Button {
            showHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18))
                .foregroundStyle(theme.onSurfaceVariant.opacity(coordinator.history == nil ? 0.3 : 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(coordinator.history == nil)
        .sheet(isPresented: $showHistory) {
            if let history = coordinator.history {
                HistoryView(history: history)
                    .preferredColorScheme(appearance.colorScheme)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            Logger.app.info("[LaunchProbe] settings button tapped main=\(Thread.isMainThread)")
            showSettings = true
            Logger.app.info("[LaunchProbe] settings showSettings=true main=\(Thread.isMainThread)")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .padding(.leading, 4)
        .sheet(isPresented: $showSettings) {
            let _ = Logger.app.info("[LaunchProbe] settings sheet content built main=\(Thread.isMainThread)")
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
                .onAppear {
                    Logger.app.info("[LaunchProbe] SettingsView onAppear main=\(Thread.isMainThread)")
                }
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
            VStack(spacing: 12) {
                actionCircle(
                    icon: { Circle().fill(theme.onSurface).frame(width: Self.recordIconSize, height: Self.recordIconSize) },
                    label: "RECORD"
                ) {
                    Task { await coordinator.startRecording() }
                }
                // The recording flow already supports starting before init
                // completes — audio buffers queue in StreamingAsrManager and
                // drain once the model is ready. The button has always been
                // wired; users just don't realize tapping during PREPARING
                // is fine.
                Text("Tap to start — transcription resumes when ready")
                    .font(.system(size: Self.hintFontSize))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
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

                // Waveform with timer and transcript overlay
                ZStack {
                    WaveformView(levels: coordinator.audioLevels)
                        .frame(height: 120)
                        .padding(.horizontal, 8)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(formatDuration(recordingStart.map { context.date.timeIntervalSince($0) } ?? 0))
                            .font(.system(size: 32, weight: .heavy, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(theme.onSurface)
                            .shadow(color: theme.background.opacity(0.9), radius: 8)
                            .shadow(color: theme.background.opacity(0.7), radius: 16)
                    }

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
                                // Non-animated scroll — avoids queuing animation
                                // transactions that compete with the waveform
                                // for main-thread time during rapid updates.
                                proxy.scrollTo("transcript", anchor: .bottom)
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
        swipeHint("Swipe to go back")
    }

    /// Animated "swipe back" hint reused on the Done page (with a "paste"
    /// label) for the deep-link-stop fallback path. The user is in the app
    /// because the keyboard's Darwin command path failed; swiping back to
    /// the host app surfaces the keyboard, whose `viewWillAppear` reads the
    /// bundled transcription from shared defaults and auto-pastes.
    private func swipeHint(_ label: String) -> some View {
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
            Text(label)
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
        ZStack {
            VStack(spacing: 28) {
                heroTitle("DONE")

                aiStatusView

                sessionInfoView

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

            if coordinator.stoppedViaDeepLink {
                VStack {
                    Spacer()
                    swipeHint("Swipe to paste")
                        .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var aiStatusView: some View {
        if coordinator.selectedPromptMode == .verbatim || coordinator.aiProcessingStatus == .idle {
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

    private var sessionInfoView: some View {
        HStack(spacing: 12) {
            if coordinator.selectedPromptMode != .verbatim {
                sessionInfoPill(coordinator.selectedPromptMode.displayName.uppercased())
            }
            // Verbatim and dictation both apply styles; assistant does not.
            if coordinator.selectedPromptMode.appliesStyles {
                sessionInfoPill(coordinator.currentTextStyle.displayName.uppercased())
            }
        }
    }

    private func sessionInfoPill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.onSurfaceVariant.opacity(0.3), lineWidth: 1)
            )
    }

    /// All three labels of the AI mode pill, used to reserve a fixed pill width
    /// so cycling between states doesn't reflow the row.
    private static let aiModeSizingLabels = ["VERBATIM", "DICTATION", "ASSISTANT"]
    /// All three labels of the text style pill.
    private static let styleSizingLabels = ["CASUAL", "MESSAGING", "FORMAL"]

    @ViewBuilder
    private var aiSessionToggle: some View {
        HStack(spacing: 10) {
            // AI mode pill: cycles Verbatim → Dictation → Assistant
            if AIProcessingSettings.hasAICapability {
                Button {
                    coordinator.cycleAIState()
                } label: {
                    sonicPill(
                        icon: "sparkles",
                        text: coordinator.selectedPromptMode.displayName.uppercased(),
                        sizingTexts: Self.aiModeSizingLabels,
                        filled: coordinator.selectedPromptMode != .verbatim
                    )
                }
            }

            // Style toggle pill: visually hidden in Assistant mode but keeps its
            // slot in the layout so the AI pill doesn't reflow horizontally.
            let styleVisible = coordinator.selectedPromptMode.appliesStyles
            Button {
                coordinator.cycleTextStyle()
            } label: {
                sonicPill(
                    text: coordinator.currentTextStyle.displayName.uppercased(),
                    sizingTexts: Self.styleSizingLabels,
                    filled: false
                )
            }
            .opacity(styleVisible ? 1 : 0)
            .allowsHitTesting(styleVisible)
            .accessibilityHidden(!styleVisible)
        }
    }

    private func sonicPill(
        icon: String? = nil,
        text: String,
        sizingTexts: [String]? = nil,
        filled: Bool
    ) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
            }
            ZStack {
                if let sizingTexts {
                    ForEach(sizingTexts, id: \.self) { t in
                        pillText(t).opacity(0)
                    }
                }
                pillText(text)
            }
        }
        .foregroundStyle(filled ? theme.surfaceLowest : theme.onSurface)
        .padding(.horizontal, 14)
        .frame(height: Self.aiPillHeight)
        .background(
            Capsule()
                .fill(filled ? theme.primary : theme.surfaceHigh)
        )
        .overlay(
            Capsule()
                .stroke(theme.onSurface, lineWidth: Self.pillBorder)
        )
    }

    private func pillText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.pillFontSize, weight: .black))
            .tracking(1.5)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 24) {
            heroTitle("ERROR")
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            brutalistButton("TRY AGAIN") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await coordinator.startRecording() }
            }
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
                .font(.system(size: 12, weight: .black))
                .tracking(2)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(theme.surfaceHigh)
                )
                .overlay(
                    Capsule()
                        .stroke(theme.onSurface, lineWidth: Self.pillBorder)
                )
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
