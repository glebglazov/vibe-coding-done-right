import SwiftUI

struct VoiceLockTabView: View {
    let settings: AppSettings
    let enrollmentCoordinator: EnrollmentCoordinator
    let hasMicrophonePermission: Bool

    // MARK: - Constants

    private static let thresholdRange: ClosedRange<Float> = 0.70...0.95
    private static let thresholdStep: Float = 0.01

    var body: some View {
        Form {
            Section("Voice Lock") {
                Toggle("Enable voice lock", isOn: Binding(
                    get: { settings.voiceLockEnabled },
                    set: { settings.voiceLockEnabled = $0 }
                ))
                .help("When enabled, recordings from unrecognized voices are discarded before transcription.")

                if settings.voiceLockEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.voiceLockThreshold * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { settings.voiceLockThreshold },
                                set: { settings.voiceLockThreshold = $0 }
                            ),
                            in: Self.thresholdRange,
                            step: Self.thresholdStep
                        )
                        Text("Higher values require a closer voice match. Lower values are more forgiving.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Voice Profile") {
                if enrollmentCoordinator.hasProfile {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Profile enrolled")
                                .font(.headline)
                            Text("Your voice is registered for verification.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProfileStatusBadge(enrolled: true)
                    }

                    HStack {
                        Button("Re-enroll Voice") {
                            enrollmentCoordinator.startEnrollment()
                        }
                        .disabled(!canEnroll)

                        Button("Delete Profile", role: .destructive) {
                            enrollmentCoordinator.deleteProfile()
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("No profile")
                                .font(.headline)
                            Text("Enroll your voice to enable voice lock.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProfileStatusBadge(enrolled: false)
                    }

                    Button("Enroll Voice") {
                        enrollmentCoordinator.startEnrollment()
                    }
                    .disabled(!canEnroll)
                }

                if case .recording(let sample) = enrollmentCoordinator.phase {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recording sample \(sample) of \(EnrollmentCoordinator.sampleCount)...")
                                .font(.subheadline)
                            Spacer()
                            Button("Cancel") {
                                enrollmentCoordinator.cancelEnrollment()
                            }
                            .controlSize(.small)
                        }
                        ProgressView(value: enrollmentCoordinator.progress)
                        Text("Speak naturally for a few seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .processing = enrollmentCoordinator.phase {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing voice profile...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = enrollmentCoordinator.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !hasMicrophonePermission {
                    Text("Microphone permission is required for enrollment.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Lock")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task {
            await enrollmentCoordinator.refreshProfileState()
        }
        .onDisappear {
            enrollmentCoordinator.tearDown()
        }
    }

    private var canEnroll: Bool {
        if case .idle = enrollmentCoordinator.phase {
            return hasMicrophonePermission
        }
        return false
    }
}

// MARK: - Profile Status Badge

private struct ProfileStatusBadge: View {
    // MARK: - Constants

    private static let dotSpacing: CGFloat = 6
    private static let dotSize: CGFloat = 8
    private static let badgeHPadding: CGFloat = 10
    private static let badgeVPadding: CGFloat = 4
    private static let badgeCornerRadius: CGFloat = 12

    let enrolled: Bool

    var body: some View {
        HStack(spacing: Self.dotSpacing) {
            Circle()
                .fill(enrolled ? Color.green : Color.gray)
                .frame(width: Self.dotSize, height: Self.dotSize)
            Text(enrolled ? "Enrolled" : "Not enrolled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.badgeHPadding)
        .padding(.vertical, Self.badgeVPadding)
        .background((enrolled ? Color.green : Color.gray).opacity(0.1))
        .cornerRadius(Self.badgeCornerRadius)
    }
}
