import Foundation

enum SharedConstants {
    static let appGroupID = "group.glebglazov.vcdr-ios"
    static let transcriptionResultKey = "pendingTranscription"
    static let darwinNotificationName = "glebglazov.vcdr-ios.transcriptionReady"
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }
}
