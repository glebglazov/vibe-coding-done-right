import Foundation

/// Maps known bundle IDs to URL schemes for returning to the host app after transcription.
/// Apple first-party apps open silently; third-party apps show a confirmation dialog.
enum AppURLSchemes {
    private static let knownSchemes: [String: String] = [
        // Apple first-party (open silently, no confirmation dialog)
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.MobileSMS": "messages://",
        "com.apple.mobilemail": "message://",
        "com.apple.mobilesafari": "x-web-search://",
        "com.apple.reminders": "x-apple-reminderkit://",
        "com.apple.Maps": "maps://",
        "com.apple.Preferences": "App-prefs://",
        "com.apple.iWork.Pages": "pages://",
        "com.apple.iWork.Numbers": "numbers://",
        "com.apple.iWork.Keynote": "keynote://",
        // Third-party (iOS shows "Open in X?" confirmation)
        "com.anthropic.claude": "claude://",
        "md.obsidian": "obsidian://",
        "ph.telegra.Telegraph": "tg://",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "org.whispersystems.signal": "sgnl://",
        "com.slack.Slack": "slack://",
        "com.atebits.Tweetie2": "twitter://",
        "com.burbn.instagram": "instagram://",
        "com.facebook.Messenger": "fb-messenger://",
        "com.spotify.client": "spotify://",
        "com.google.chrome.ios": "googlechrome://",
        "com.microsoft.Office.Word": "ms-word://",
        "com.microsoft.Office.Outlook": "ms-outlook://",
        "com.todoist.ios": "todoist://",
        "com.culturedcode.ThingsiPhone": "things://",
        "notion.id": "notion://",
        "com.hammerandchisel.discord": "discord://",
        "com.linear": "linear://",
        "com.google.Translate": "googletranslate://",
    ]

    /// Returns the URL scheme for a known bundle ID, or nil if unknown.
    static func url(forBundleID bundleID: String) -> URL? {
        guard let scheme = knownSchemes[bundleID] else { return nil }
        return URL(string: scheme)
    }
}
