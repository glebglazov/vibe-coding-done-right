import KeyboardKit

extension KeyboardApp {
    static var vcdr: KeyboardApp {
        .init(
            name: "VCDR",
            appGroupId: SharedConstants.appGroupID,
            locales: [.english]
        )
    }
}
