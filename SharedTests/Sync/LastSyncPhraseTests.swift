import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// Pins the bands the Last Sync Time reads in, against a fixed reference date
/// and a fixed locale and calendar — never the wall clock, so a run at 23:59
/// reads the same as one at noon. One source tree compiled into both
/// `vcdr-macTests` and `vcdr-iosTests`.
@Suite("LastSyncPhrase")
struct LastSyncPhraseTests {

    /// Wednesday 15 November 2023, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_049_600)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func phrase(age: TimeInterval) -> LastSyncPhrase {
        LastSyncPhrase.of(
            now.addingTimeInterval(-age),
            at: now,
            calendar: calendar,
            locale: Locale(identifier: "en_GB")
        )
    }

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    @Test(
        "each band reads in its own words",
        arguments: [
            (0.0, "just now"),
            (59.0, "just now"),
            (60.0, "1 minute ago"),
            (300.0, "5 minutes ago"),
            (3_540.0, "59 minutes ago"),
            (3_600.0, "1 hour ago"),
            (7_200.0, "2 hours ago"),
            (39_600.0, "11 hours ago"),
            (86_400.0, "yesterday"),
            (259_200.0, "3 days ago"),
            (518_400.0, "6 days ago"),
            (604_800.0, "on 8 Nov"),
            (7_776_000.0, "on 17 Aug")
        ]
    )
    func bandWords(age: TimeInterval, expected: String) {
        #expect(phrase(age: age).words == expected)
    }

    @Test("a settled reading never counts seconds")
    func neverShowsSeconds() {
        for age in stride(from: 0.0, through: 3 * Self.day, by: 137) {
            #expect(!phrase(age: age).words.contains("second"))
        }
    }

    @Test("each band is looked at only as often as it can change")
    func refreshCadenceMatchesBand() {
        #expect(phrase(age: 10).staysTrueFor == 50)
        #expect(phrase(age: 5 * Self.minute + 20).staysTrueFor == 40)
        #expect(phrase(age: 2 * Self.hour).staysTrueFor == Self.hour)
        #expect(phrase(age: 3 * Self.day).staysTrueFor == 12 * Self.hour)
    }
}
