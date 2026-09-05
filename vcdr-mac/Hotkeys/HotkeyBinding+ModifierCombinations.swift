import CoreGraphics

extension HotkeyBinding {

    /// The four modifiers a binding can require.
    private static let matchableModifiers: [CGEventFlags] = [
        .maskControl, .maskAlternate, .maskShift, .maskCommand
    ]

    /// Every modifier state a key press can arrive in, as far as matching cares:
    /// the 16 subsets of those four.
    ///
    /// An event tap saw the modifiers and could decide; Carbon matches a
    /// combination exactly and cannot. So a rule stated over modifiers — "any
    /// combination that includes these", "this key whatever is held" — is claimed
    /// by running the rule over all sixteen and claiming what it picks.
    static let modifierCombinations: [UInt64] = matchableModifiers
        .indices
        .reduce(into: [UInt64(0)]) { combinations, index in
            let bits = matchableModifiers[index].rawValue
            combinations += combinations.map { $0 | bits }
        }

    /// `keyCode` under every modifier state, so it answers however many modifiers
    /// the user happens to be holding — which push-to-talk makes routine.
    static func everyCombination(of keyCode: UInt16) -> [HotkeyBinding] {
        modifierCombinations.map { HotkeyBinding(keyCode: keyCode, modifiers: $0) }
    }
}
