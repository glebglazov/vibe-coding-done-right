import Carbon
import CoreGraphics

extension HotkeyBinding {

    /// The four modifiers, paired with the two numberings the app has to bridge.
    /// A binding stores the `CGEventFlags` bits the shortcut recorder captured;
    /// `RegisterEventHotKey` counts the same modifiers in Carbon's own bits, so a
    /// binding cannot reach the registry unconverted.
    private static let carbonEquivalents: [(flag: CGEventFlags, carbon: Int)] = [
        (.maskCommand, cmdKey),
        (.maskShift, shiftKey),
        (.maskAlternate, optionKey),
        (.maskControl, controlKey)
    ]

    /// This binding's modifiers in the mask `RegisterEventHotKey` expects.
    var carbonModifiers: UInt32 {
        let flags = CGEventFlags(rawValue: modifiers)
        return Self.carbonEquivalents.reduce(into: UInt32(0)) { mask, equivalent in
            if flags.contains(equivalent.flag) { mask |= UInt32(equivalent.carbon) }
        }
    }
}
