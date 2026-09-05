import Foundation

/// How current the device is, in the coarse bands a person acts on, and how
/// long that reading stays true.
///
/// Relative wording holds all the way to a week because relative wording *is*
/// the staleness answer: "3 days ago" alarms on sight where a clock time makes
/// the reader work the difference out. Past a week the relative form goes
/// vague and a date is the better anchor, so that is where it crosses over.
///
/// Nothing here is finer than a minute. A count moving while nothing happens
/// competes with the spinner, which is the one thing in the control that
/// should earn attention by moving.
struct LastSyncPhrase: Equatable {

    /// The words after "synced" — "just now", "5 minutes ago", "on 12 Aug".
    let words: String

    /// How long until the words could read differently, so a label showing
    /// them knows when to look again. A band that changes daily is looked at
    /// daily; only the first minute after a pass is watched closely.
    let staysTrueFor: TimeInterval

    // MARK: - Constants

    /// The two clock bands' boundaries, in seconds: under a minute reads "just
    /// now", under an hour counts minutes, and past that it counts hours. The
    /// same two also space out the refreshes inside those bands.
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600

    /// A week is where relative wording stops saying anything useful, in days.
    private static let relativeWordingLimit = 7

    /// Reads a Last Sync Time as of a given moment. The moment is a parameter
    /// rather than `Date.now` so the bands can be exercised against a fixed
    /// reference date.
    static func of(
        _ lastSyncTime: Date,
        at now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LastSyncPhrase {
        let age = max(0, now.timeIntervalSince(lastSyncTime))
        let untilMidnight = untilNextMidnight(after: now, calendar: calendar)
        let dayGap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lastSyncTime),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        func relative(_ field: Date.RelativeFormatStyle.Field) -> String {
            // The anchor is the moment described and the receiver the moment
            // it is described from — the reverse of how the argument label
            // reads, which the band tests pin down.
            now.formatted(Date.AnchoredRelativeFormatStyle(
                anchor: lastSyncTime,
                allowedFields: [field],
                presentation: .named,
                unitsStyle: .wide,
                locale: locale,
                calendar: calendar
            ))
        }

        switch (age, dayGap) {
        case (..<Self.minute, _):
            return LastSyncPhrase(words: "just now", staysTrueFor: Self.minute - age)
        case (..<Self.hour, _):
            return LastSyncPhrase(
                words: relative(.minute),
                staysTrueFor: Self.minute - age.truncatingRemainder(dividingBy: Self.minute)
            )
        case (_, 0):
            return LastSyncPhrase(
                words: relative(.hour),
                staysTrueFor: min(
                    Self.hour - age.truncatingRemainder(dividingBy: Self.hour),
                    untilMidnight
                )
            )
        case (_, 1...(Self.relativeWordingLimit - 1)):
            return LastSyncPhrase(words: relative(.day), staysTrueFor: untilMidnight)
        default:
            var dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
            dateStyle.calendar = calendar
            dateStyle.timeZone = calendar.timeZone
            return LastSyncPhrase(
                words: "on \(lastSyncTime.formatted(dateStyle))",
                staysTrueFor: untilMidnight
            )
        }
    }

    /// The day-based bands change when the calendar day does, not when the age
    /// crosses a multiple of 24 hours.
    ///
    /// A calendar with no next midnight is not a calendar; the fallback is there
    /// so an unreachable answer re-reads within the hour rather than never.
    private static func untilNextMidnight(after now: Date, calendar: Calendar) -> TimeInterval {
        guard let midnight = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) else { return Self.hour }
        return midnight.timeIntervalSince(now)
    }
}
