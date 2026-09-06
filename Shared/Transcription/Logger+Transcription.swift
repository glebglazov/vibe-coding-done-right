import OSLog

/// Transcription subsystem logger — the providers on either platform and the
/// model root they resolve through, which belongs to neither product and so
/// cannot take a channel either one declares.
extension Logger {
    static let transcription = AppLog(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr.transcription",
        category: "transcription"
    )
}
