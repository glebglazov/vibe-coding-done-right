import OSLog
import SwiftUI
import UIKit

struct RecordingView: View {
    @Bindable var coordinator: RecordingFlowCoordinator
    let conversationReprocessor: any ConversationReprocessor
    @Environment(\.colorScheme) private var colorScheme
    private var theme: Theme { Theme.current(for: colorScheme) }
    @State private var showCopiedConfirmation = false
    @State private var recordingStart: Date?

    // MARK: - Constants
    private static let copiedConfirmationDuration: Duration = .seconds(3)
    private static let discardNoteFade: Double = 0.2
    private static let recordIconSize: CGFloat = 36
    private static let dotGridSpacing: CGFloat = 40
    private static let dotGridRadius: CGFloat = 0.5
    private static let transcriptFontSize: CGFloat = 18
    private static let transcriptMaxHeight: CGFloat = 200
    private static let hintFontSize: CGFloat = 13
    private static let returnPulseDuration: Double = 0.8
    private static let aiPillHeight: CGFloat = 36
    private static let warmingPillHeight: CGFloat = 30
    private static let pillBorder: CGFloat = 1.5
    private static let pillFontSize: CGFloat = 12
    /// Clearance under the safe area for the header line — the status row and
    /// the App Shell icons together.
    private static let headerTopPadding: CGFloat = 12
    private static let runCenterHeight: CGFloat = 120
    /// STOP sits this far above the bottom safe area in every run, keyboard
    /// start or app start, clear of the bottom-edge swipe hint.
    private static let stopDockBottomPadding: CGFloat = 112
    private static let discardNoteBottomPadding: CGFloat = 24
    private static let discardNoteHorizontalPadding: CGFloat = 24
    /// Mode and style while they are locked: visible, but plainly not live.
    private static let lockedPillOpacity: Double = 0.35
    /// The return hint points up at the system back link in the status bar's
    /// leading corner, so it sits just under it, above the status row.
    private static let returnHintTopPadding: CGFloat = 4
    private static let returnHintLeadingPadding: CGFloat = 20

    var body: some View {
        ZStack {
            theme.surfaceLowest.ignoresSafeArea()
            dotGrid

            VStack(spacing: 0) {
                header
                stateContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomArea
            }

            if showsReturnHint {
                returnHint
                    .padding(.leading, Self.returnHintLeadingPadding)
                    .padding(.top, Self.returnHintTopPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                EdgeSwipeHint()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if let note = coordinator.discardNotes.note {
                DiscardNoteView(note: note) { coordinator.discardNotes.viewInHistory() }
                    .padding(.horizontal, Self.discardNoteHorizontalPadding)
                    .padding(.bottom, Self.discardNoteBottomPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: Self.discardNoteFade), value: coordinator.discardNotes.note)
        .onChange(of: coordinator.state) { _, newState in
            if case .recording = newState {
                recordingStart = .now
            } else {
                recordingStart = nil
            }
        }
        // Propagate theme to child views (WaveformView) via environment
        .environment(\.theme, theme)
        // The host app's keyboard is still up as VCDR opens from it. This page
        // has no text field, so it must not lift the STOP button out of the way.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // PROBE: confirms the host keyboard reaches this page on a keyboard start.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            Logger.app.notice("PROBE keyboard frame change end=\(frame.map { "\($0)" } ?? "nil") state=\(coordinator.state)")
        }
    }

    // MARK: - Header

    /// The status row and the App Shell icons share one line. The icons only
    /// ever occupy its trailing end, so the row costs no vertical space of its
    /// own and the screen's content starts that much higher. The line keeps the
    /// icons' height whether or not they are rendered — while arming and
    /// recording the cluster is gone and the text has the line to itself,
    /// centred as it is on the keyboard, but nothing below it shifts.
    private var header: some View {
        HStack(spacing: 0) {
            statusRow
            topBar
        }
        .frame(height: RecordingTopBar.height)
        .padding(.top, Self.headerTopPadding)
    }

    @ViewBuilder
    private var topBar: some View {
        switch coordinator.state {
        case .arming, .recording:
            EmptyView()
        default:
            RecordingTopBar(
                coordinator: coordinator,
                conversationReprocessor: conversationReprocessor,
                discardNotes: coordinator.discardNotes,
                history: coordinator.history,
                historySync: coordinator.historySync,
                substitutionStore: coordinator.substitutionStore,
                substitutionSync: coordinator.substitutionSync
            )
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

        case .arming:
            armingContent

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
                InitProgressLabel(coordinator: coordinator, theme: theme)
            }
            VStack(spacing: 12) {
                recordButton
                // The recording flow already supports starting before init
                // completes — audio buffers queue in the live session and
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
            VStack(spacing: 16) {
                heroTitle("READY")
                if coordinator.isModelWarming {
                    warmingPill
                }
            }
            recordButton
        }
    }

    private var warmingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(theme.primary)
                .scaleEffect(0.7)
            Text("Model warming")
                .font(.system(size: Self.pillFontSize, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(height: Self.warmingPillHeight)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(theme.surfaceHigh.opacity(0.7))
        )
        .overlay(
            Capsule()
                .stroke(theme.onSurfaceVariant.opacity(0.35), lineWidth: Self.pillBorder)
        )
    }

    /// Arming phase: the tap is acknowledged and the audio engine is warming.
    /// Deliberately shows NO timer and NO waveform — nothing is being captured
    /// yet, so a running timer or moving waveform would be a lie. STOP cancels
    /// the warming engine (cancellation, no result).
    private var armingContent: some View {
        runLayout(title: "STARTING…") {
            VStack(spacing: 16) {
                ProgressView()
                    .tint(theme.primary)
                    .scaleEffect(1.2)
                Text("Warming up the mic")
                    .font(.system(size: Self.hintFontSize))
                    .foregroundStyle(theme.onSurfaceVariant.opacity(0.7))
            }
        }
    }

    private var recordButton: some View {
        ActionCircle(label: "RECORD") {
            Task { await coordinator.startRecording(origin: .app) }
        } icon: {
            Circle().fill(theme.onSurface).frame(width: Self.recordIconSize, height: Self.recordIconSize)
        }
    }

    private var recordingContent: some View {
        runLayout(title: "LISTENING") {
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
        }
    }

    /// Arming and Recording share one layout, so the switch to Capturing
    /// changes only the title and the centre, and nothing moves. The title,
    /// centre and pills are centred in the space between the header and the
    /// controls, not in the whole page, so the group stays balanced above STOP.
    private func runLayout<Center: View>(title: String, @ViewBuilder center: () -> Center) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                heroTitle(title)
                    .padding(.bottom, 8)

                center()
                    .frame(height: Self.runCenterHeight)

                aiSessionToggle
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            RunControlDock(
                onStop: { Task { await coordinator.stopActiveRun() } },
                onDiscard: { Task { await coordinator.discardRecording() } }
            )
            .padding(.bottom, Self.stopDockBottomPadding)
        }
    }

    /// The reserved status row at the top of the screen. Its height is
    /// reserved in every phase, so nothing reflows when a run begins or ends.
    private var statusRow: some View {
        StatusRow(
            status: transientStatus,
            fontSize: Self.hintFontSize,
            color: theme.onSurfaceVariant
        )
    }

    /// The run-adjacent states that had nowhere to say anything before the row
    /// became a status line. An empty result is not one of them here: the
    /// error content in the middle of the page already says it.
    private var transientStatus: TransientStatus? {
        switch coordinator.state {
        case .transcribing: .transcribing
        default: nil
        }
    }

    private var showsReturnHint: Bool {
        switch coordinator.state {
        case .arming, .recording: coordinator.isKeyboardRun
        default: false
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
                        Task { await coordinator.startRecording(origin: .app) }
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
            sessionInfoPill(coordinator.currentTextStyle.displayName.uppercased())
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

    /// Both labels of the AI pill, used to reserve a fixed pill width so a
    /// toggle doesn't reflow the row.
    private static let aiModeSizingLabels = AIPromptMode.allCases.map { $0.displayName.uppercased() }
    /// All three labels of the text style pill.
    private static let styleSizingLabels = ["CASUAL", "MESSAGING", "FORMAL"]

    /// Locked while the run listens (ADR-0010): dimmed and inert, but still on
    /// screen so the user can see what the run will use.
    @ViewBuilder
    private var aiSessionToggle: some View {
        let locked = coordinator.areOutputChoicesLocked
        HStack(spacing: 10) {
            if AIProcessingSettings.hasAICapability {
                let aiOn = coordinator.selectedPromptMode == .dictation
                Button {
                    coordinator.toggleAIMode()
                } label: {
                    sonicPill(
                        icon: aiOn ? "sparkles" : nil,
                        text: coordinator.selectedPromptMode.displayName.uppercased(),
                        sizingTexts: Self.aiModeSizingLabels,
                        filled: aiOn
                    )
                }
                .accessibilityLabel("AI")
                .accessibilityValue(aiOn ? "On" : "Off")
            }

            Button {
                coordinator.cycleTextStyle()
            } label: {
                sonicPill(
                    text: coordinator.currentTextStyle.displayName.uppercased(),
                    sizingTexts: Self.styleSizingLabels,
                    filled: false
                )
            }
        }
        .opacity(locked ? Self.lockedPillOpacity : 1)
        .disabled(locked)
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
                Task { await coordinator.startRecording(origin: .app) }
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

private struct InitProgressLabel: View {
    let coordinator: RecordingFlowCoordinator
    let theme: Theme

    var body: some View {
        Text(coordinator.initProgress.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(3)
            .foregroundStyle(theme.onSurfaceVariant)
    }
}
