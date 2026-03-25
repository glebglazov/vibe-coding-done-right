import Foundation

/// Maps known bundle IDs to their URL schemes for the bounce-back after audio session activation.
/// Apps not in this table fall back to the iOS "Back to" banner.
enum AppURLSchemes {
    private static let knownSchemes: [String: String] = [
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.MobileSMS": "messages://",
        "com.apple.mobilemail": "message://",
        "com.apple.mobilesafari": "x-web-search://",
        "com.apple.MobileStore": "itms-apps://",
        "com.apple.reminders": "x-apple-reminderkit://",
        "com.apple.Maps": "maps://",
        "com.apple.Preferences": "App-prefs://",
        "com.burbn.instagram": "instagram://",
        "org.whispersystems.signal": "sgnl://",
        "ph.telegra.Telegraph": "tg://",
        "net.whatsapp.WhatsApp": "whatsapp://",
        "com.atebits.Tweetie2": "twitter://",
        "com.slack.Slack": "slack://",
        "com.facebook.Messenger": "fb-messenger://",
        "com.spotify.client": "spotify://",
    ]

    static func urlScheme(forBundleID bundleID: String) -> String? {
        knownSchemes[bundleID]
    }
}
