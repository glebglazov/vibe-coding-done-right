import CoreGraphics
import Foundation
import OSLog

/// Holds the claims behind every Output Destination's Activation Hotkey.
///
/// An Activation Hotkey matches any combination that *includes* its modifiers:
/// that is what lets Option+P fire while push-to-talk holds Control and Command
/// down, and what makes Shift+Option+P beat Option+P on the same key. Carbon
/// matches a combination exactly and knows neither rule, so the answer is
/// precomputed instead of compared — each Activation Hotkey claims its whole
/// Modifier Expansion, and a press is then a lookup.
@MainActor
final class DestinationHotkeyManager {

    /// One Output Destination's Activation Hotkey, as armed. Only assigned
    /// hotkeys are kept, so an unbound destination claims nothing.
    private struct ArmedBinding: Equatable {
        let id: UUID
        let hotkey: HotkeyBinding
    }

    private let registry: any HotkeyRegistry
    private var armed: [ArmedBinding] = []
    private var claims: [HotkeyClaim] = []

    /// Called with the Output Destination whose Activation Hotkey was pressed.
    var onDestinationMatched: ((UUID) -> Void)?

    init(registry: any HotkeyRegistry) {
        self.registry = registry
    }

    // MARK: - Arming

    /// Claims the Modifier Expansion of every assigned Activation Hotkey in
    /// `bindings`, dropping whatever was claimed before.
    ///
    /// Releases first and claims after, unconditionally: the window server
    /// refuses a second registration of a combination that is still claimed, so
    /// re-arming the same shortcut only works in that order.
    func arm(bindings: [(id: UUID, hotkey: HotkeyBinding)]) {
        let incoming = bindings.compactMap { binding -> ArmedBinding? in
            guard binding.hotkey.isAssigned else { return nil }
            return ArmedBinding(id: binding.id, hotkey: binding.hotkey)
        }

        // Every change to the destination list re-arms, and most of those changes
        // — a rename, a script edit, a reorder — leave the Activation Hotkeys
        // alone. Releasing and re-claiming for those would open a window
        // mid-recording where the key press reaches the frontmost app, for no gain.
        guard incoming != armed else { return }

        disarm()
        armed = incoming

        for binding in incoming where binding.hotkey.modifiers == 0 {
            Logger.hotkeys.warning(
                """
                Activation Hotkey \(binding.hotkey.displayString) requires no modifiers, \
                so while recording it claims every combination of that key, ⌘ included
                """
            )
        }

        let flattened = incoming.map { (id: $0.id, keyCode: $0.hotkey.keyCode, modifiers: $0.hotkey.modifiers) }
        claims = Self.modifierExpansion(of: flattened).compactMap { claimed in
            registry.claim(claimed.combination) { [weak self] in
                self?.onDestinationMatched?(claimed.destinationID)
            }
        }
        Logger.hotkeys.info("Activation Hotkeys: claimed \(self.claims.count) combinations")
    }

    /// Hands every claimed combination back to the frontmost app.
    func disarm() {
        for claim in claims { claim.release() }
        claims = []
        armed = []
    }

    // MARK: - Shared Matching

    /// Matches a key event against hotkey bindings using superset modifier matching.
    /// Extra modifiers on the event are allowed. When multiple bindings share the same
    /// keyCode, the most specific match (most required modifier bits) wins.
    /// Returns the UUID of the best match, or nil if none matched.
    nonisolated static func matchBinding(
        keyCode: UInt16,
        modifierBits: UInt64,
        bindings: [(id: UUID, keyCode: UInt16, modifiers: UInt64)]
    ) -> UUID? {
        var bestMatch: (id: UUID, specificity: Int)?
        for binding in bindings where binding.keyCode != 0 || binding.modifiers != 0 {
            if keyCode == binding.keyCode
                && (modifierBits & binding.modifiers) == binding.modifiers {
                let specificity = binding.modifiers.nonzeroBitCount
                if bestMatch == nil || specificity > bestMatch!.specificity {
                    bestMatch = (binding.id, specificity)
                }
            }
        }
        return bestMatch?.id
    }

    // MARK: - Modifier Expansion

    /// Every combination the given Activation Hotkeys answer to, paired with the
    /// Output Destination each one fires.
    ///
    /// This is `matchBinding` run forwards: for each key involved, all 16 modifier
    /// combinations are asked who would win them, so the superset match and the
    /// specificity tie-break are literally the same rule an event tap applied. A
    /// combination therefore appears at most once — Carbon refuses a duplicate
    /// registration from the same process, and a duplicate would mean this had a bug.
    nonisolated static func modifierExpansion(
        of bindings: [(id: UUID, keyCode: UInt16, modifiers: UInt64)]
    ) -> [(combination: HotkeyBinding, destinationID: UUID)] {
        let combinations = matchableModifierCombinations()
        let keyCodes = bindings.map(\.keyCode).reduce(into: [UInt16]()) { unique, keyCode in
            if !unique.contains(keyCode) { unique.append(keyCode) }
        }

        return keyCodes.flatMap { keyCode in
            combinations.compactMap { modifiers -> (combination: HotkeyBinding, destinationID: UUID)? in
                guard let destinationID = matchBinding(
                    keyCode: keyCode,
                    modifierBits: modifiers,
                    bindings: bindings
                ) else { return nil }
                return (HotkeyBinding(keyCode: keyCode, modifiers: modifiers), destinationID)
            }
        }
    }

    /// The 16 subsets of the four modifiers an Activation Hotkey can require —
    /// every modifier state a key press can arrive in, as far as matching cares.
    private nonisolated static func matchableModifierCombinations() -> [UInt64] {
        let modifiers: [CGEventFlags] = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return (0..<(1 << modifiers.count)).map { subset in
            modifiers.enumerated().reduce(into: UInt64(0)) { bits, modifier in
                if subset & (1 << modifier.offset) != 0 { bits |= modifier.element.rawValue }
            }
        }
    }
}
