import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

private enum PresenceFace {
    case live(MicPresenceCardState)
    case notReady

    init(isStale: Bool, state: MicPresenceCardState) {
        self = isStale ? .notReady : .live(state)
    }

    var title: String {
        switch self {
        case .live(.ready): "Ready to record"
        case .live(.arming): "Starting…"
        case .live(.capturing): "Recording"
        case .live(.finalizing): "Transcribing…"
        case .live(.concluded(.copied)): "Copied"
        case .live(.concluded(.noSpeech)): "No speech detected"
        case .live(.concluded(.failed)): "Couldn't transcribe"
        /// VCDR is no longer reachable in place, so the card must claim nothing:
        /// the next keyboard tap opens the app instead of recording where the
        /// user is typing (ADR-0006).
        case .notReady: "VCDR is not running"
        }
    }

    var tag: String {
        switch self {
        case .live(.ready): "Ready"
        case .live(.arming), .live(.finalizing): "…"
        case .live(.capturing): "REC"
        case .live(.concluded(.copied)): "Copied"
        case .live(.concluded(.noSpeech)), .live(.concluded(.failed)): "None"
        case .notReady: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .live(.ready): "waveform"
        case .live(.arming), .live(.capturing): "mic.fill"
        case .live(.finalizing): "text.bubble"
        case .live(.concluded(.copied)): "doc.on.clipboard"
        case .live(.concluded(.noSpeech)): "speaker.slash"
        case .live(.concluded(.failed)): "exclamationmark.triangle"
        case .notReady: "waveform.slash"
        }
    }

    var accent: Color {
        switch self {
        case .live(.capturing): Color(red: 0.90, green: 0.22, blue: 0.27)
        case .notReady: .secondary
        case .live: .primary
        }
    }

    var capturingSince: Date? {
        guard case .live(.capturing(let since)) = self else { return nil }
        return since
    }

    var stopTitle: String? {
        guard case .live(let state) = self else { return nil }
        switch state.stopControl {
        case .cancel?: return "Cancel"
        case .stop?: return "Stop"
        case nil: return nil
        }
    }

    var isNotReady: Bool {
        guard case .notReady = self else { return false }
        return true
    }

    var isCapturing: Bool { capturingSince != nil }
}

struct HotMicLiveActivity: Widget {
    /// Wide enough for "0:00:00" in the compact trailing slot, which otherwise
    /// gives a timer the whole island.
    private static let compactTimerWidth: CGFloat = 44

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HotMicActivityAttributes.self) { context in
            let face = PresenceFace(isStale: context.isStale, state: context.state)
            HStack(spacing: 12) {
                iconBadge(size: 40, face: face)
                caption(face: face, titleFont: .body.weight(.medium))
                Spacer()
                stopButton(face: face)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let face = PresenceFace(isStale: context.isStale, state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    iconBadge(size: 32, face: face)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if face.isCapturing {
                        Circle()
                            .fill(face.accent)
                            .frame(width: 10, height: 10)
                            .frame(maxHeight: .infinity, alignment: .center)
                    } else {
                        EmptyView()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    caption(face: face, titleFont: .callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    stopButton(face: face)
                }
            } compactLeading: {
                iconBadge(size: 20, face: face)
            } compactTrailing: {
                if let since = face.capturingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(face.accent)
                        .frame(width: Self.compactTimerWidth)
                } else {
                    Text(face.tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(face.accent)
                }
            } minimal: {
                iconBadge(size: 20, face: face)
            }
        }
    }

    @ViewBuilder
    private func caption(face: PresenceFace, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VCDR")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(face.title)
                if let since = face.capturingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .font(titleFont)
            .foregroundStyle(face.accent)
        }
    }

    @ViewBuilder
    private func stopButton(face: PresenceFace) -> some View {
        if let title = face.stopTitle {
            Button(intent: StopRecordingIntent()) {
                Label(title, systemImage: "stop.fill")
            }
            .tint(face.accent)
        }
    }

    /// Tinted red while capturing and drained of colour once not ready, so the
    /// card reads at a glance — the wording is the claim, the tint is how urgent
    /// it is.
    @ViewBuilder
    private func iconBadge(size: CGFloat, face: PresenceFace) -> some View {
        ZStack {
            if face.isCapturing {
                face.accent
            } else {
                LinearGradient(
                    colors: [Color(red: 0.32, green: 0.68, blue: 0.70),
                             Color(red: 0.82, green: 0.42, blue: 0.52)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            Image(systemName: face.symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .grayscale(face.isNotReady ? 1 : 0)
        .opacity(face.isNotReady ? 0.5 : 1)
    }
}
