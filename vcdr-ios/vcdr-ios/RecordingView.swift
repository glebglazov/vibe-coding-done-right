import SwiftUI

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCopiedConfirmation = false
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

    var body: some View {
        ZStack {
            Theme.surfaceLowest.ignoresSafeArea()
            dotGrid

            VStack(spacing: 0) {
                topBar
                stateContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomArea
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: coordinator.state) { _, newState in
            if case .recording = newState {
                recordingStart = .now
            } else {
                recordingStart = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When app goes to background during a deep-link recording,
            // auto-stop and send the transcription to the keyboard.
            if newPhase == .background,
               coordinator.launchedViaDeepLink,
               case .recording = coordinator.state {
                Task { await coordinator.stopAndTranscribe() }
            }
        }
    }

    // MARK: - Top Bar (non-recording states only)

    @ViewBuilder
    private var topBar: some View {
        if case .recording = coordinator.state {
            EmptyView()
        } else {
            Spacer().frame(height: 56)
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
        VStack(spacing: 24) {
            heroTitle("PREPARING")
            ProgressView()
                .tint(Theme.primary)
                .scaleEffect(1.2)
            Text(coordinator.initProgress.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(3)
                .foregroundStyle(Theme.onSurfaceVariant)
        }
    }

    private var readyContent: some View {
        VStack(spacing: 40) {
            heroTitle("READY")
            actionCircle(
                icon: { Circle().fill(Theme.onSurface).frame(width: Self.recordIconSize, height: Self.recordIconSize) },
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
                        .foregroundStyle(Theme.primary.opacity(0.8))
                }
                .padding(.bottom, 32)

                WaveformView(levels: coordinator.audioLevels)
                    .frame(height: 120)
                    .padding(.horizontal, 8)
            }

            // Bottom-pinned content — transcript, hint, stop button
            VStack(spacing: 0) {
                Spacer()

                if !coordinator.liveTranscript.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(coordinator.liveTranscript)
                                .font(.system(size: Self.transcriptFontSize, weight: .light))
                                .foregroundStyle(Theme.onSurface.opacity(0.7))
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 32)
                                .id("transcript")
                        }
                        .frame(maxHeight: Self.transcriptMaxHeight)
                        .onChange(of: coordinator.liveTranscript) {
                            withAnimation {
                                proxy.scrollTo("transcript", anchor: .bottom)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }

                if coordinator.launchedViaDeepLink {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: Self.hintFontSize))
                        Text("Switch back to paste")
                            .font(.system(size: Self.hintFontSize, weight: .medium))
                    }
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .padding(.bottom, 16)
                }

                actionCircle(
                    icon: {
                        Rectangle()
                            .fill(Theme.onSurface)
                            .frame(width: Self.stopIconSize, height: Self.stopIconSize)
                    },
                    label: "STOP"
                ) {
                    Task { await coordinator.stopAndTranscribe() }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var transcribingContent: some View {
        VStack(spacing: 24) {
            heroTitle("PROCESSING")
            ProgressView()
                .tint(Theme.primary)
                .scaleEffect(1.2)
        }
    }

    private func completeContent(_ text: String) -> some View {
        VStack(spacing: 28) {
            heroTitle("DONE")

            HStack(alignment: .top, spacing: 16) {
                Rectangle()
                    .fill(Theme.primary)
                    .frame(width: 2)
                Text(text)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.onSurface)
                    .lineSpacing(6)
            }
            .frame(maxHeight: 140)
            .padding(.horizontal, 32)

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
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 24) {
            heroTitle("ERROR")
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.onSurfaceVariant)
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
            .foregroundStyle(Theme.onSurface)
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
                        .fill(Theme.primaryDim)
                        .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                        .shadow(color: Theme.primaryDim.opacity(0.2), radius: 20)
                    Circle()
                        .stroke(Theme.surfaceHighest, lineWidth: Self.actionButtonBorder)
                        .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                    icon()
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(3)
                .foregroundStyle(Theme.onSurface)
        }
    }

    private func brutalistButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.onSurface)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.surfaceHigh)
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
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.04)))
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
