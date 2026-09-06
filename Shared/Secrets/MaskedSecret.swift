import Foundation

extension String {

    /// The secret as it reads before the user asks to see it: its first and last
    /// few characters, with bullets standing in for everything between them. The
    /// visible ends are what lets someone tell one key from another without the
    /// screen showing either in full.
    ///
    /// A secret too short for that is hidden whole — its ends would be the secret.
    var maskedAsSecret: String {
        guard count > Self.maskedSecretVisibleEnd * 2 else {
            return isEmpty ? "Not set" : String(repeating: Self.maskedSecretBullet, count: count)
        }
        let bullets = String(repeating: Self.maskedSecretBullet, count: Self.maskedSecretVisibleEnd)
        return "\(prefix(Self.maskedSecretVisibleEnd))\(bullets)\(suffix(Self.maskedSecretVisibleEnd))"
    }

    // MARK: - Constants

    /// How many characters stay legible at each end.
    private static let maskedSecretVisibleEnd = 3
    private static let maskedSecretBullet = "\u{2022}"
}
