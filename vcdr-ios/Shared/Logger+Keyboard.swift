import Foundation
import OSLog

nonisolated extension Logger {
    static let keyboard = AppLog(
        subsystem: Bundle.main.bundleIdentifier ?? "vcdr-ios.keyboard",
        category: "keyboard"
    )
}
