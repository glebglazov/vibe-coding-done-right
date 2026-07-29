import Combine
import KeyboardKit
import SwiftUI
import UIKit

/// Owns the keyboard's Compact/Full display mode.
///
/// KeyboardKit's `isKeyboardCollapsed` decides *which* view renders — the
/// collapsed strip or the key rows — but does not own the extension's frame.
/// This manager reacts to the flag: it persists the chosen mode (so it
/// survives appearances, host apps, and process teardown) and pins the frame
/// to a deterministic Compact height, releasing it in Full so the keyboard
/// sizes itself exactly as it did before Compact existed.
///
/// The only writers of the collapse flag are `expand()`/`collapse()` —
/// recording never collapses and inserting never expands — and KeyboardKit's
/// own auto-collapse on external keyboards is off by default, so the mode
/// never moves without a user tap.
@MainActor
final class KeyboardDisplayModeManager {

    // MARK: - Constants

    /// Height the keyboard claims in Compact: exactly what the compact layout
    /// needs, since anything more is dead space rather than reclaimed screen.
    static var compactKeyboardHeight: CGFloat { CompactKeyboardView.intrinsicHeight }

    /// Height of the Full Keyboard's toolbar strip. Shared with
    /// `VCDRKeyboardView`'s `keyboardToolbarStyle` so the predicted Full
    /// height below and the rendered strip cannot drift apart.
    static let fullToolbarHeight: CGFloat = 44

    /// One notch below `.required`: beats SwiftUI content sizing, still
    /// breakable by the system's own required constraints (rotation, iPad
    /// floating keyboard).
    private static let heightConstraintPriority = UILayoutPriority(999)

    private let keyboardContext: KeyboardContext
    private weak var inputView: UIView?
    private var heightConstraint: NSLayoutConstraint?
    private var cancellables = Set<AnyCancellable>()

    init(keyboardContext: KeyboardContext, inputView: UIView) {
        self.keyboardContext = keyboardContext
        self.inputView = inputView
    }

    /// Lands the keyboard in the persisted mode and wires every later flip
    /// to persistence. Call once from `viewDidLoad`, before the first frame,
    /// so the keyboard opens in the right state and size.
    ///
    /// Persistence is all this subscription does. Height is driven by
    /// `expand()`/`collapse()` instead, because those have to order the frame
    /// change against the flag flip — a sink reacting to the flag can only
    /// ever run after it.
    func activate() {
        let collapsed = KeyboardDisplayModeStore.current() == .compact
        setCollapsed(collapsed)
        if collapsed { pinHeight(to: Self.compactKeyboardHeight) }

        keyboardContext.$isKeyboardCollapsed
            .removeDuplicates()
            .sink { collapsed in
                KeyboardDisplayModeStore.set(collapsed ? .compact : .full)
            }
            .store(in: &cancellables)
    }

    /// Re-asserts the height constraint on each appearance — the system can
    /// drop or override view constraints between appearances.
    func reassertHeight() {
        if keyboardContext.isKeyboardCollapsed {
            pinHeight(to: Self.compactKeyboardHeight)
        } else {
            releaseHeight()
        }
    }

    /// Switches to Full: the already-built key rows return instantly.
    ///
    /// Grows the frame *before* flipping the flag. Flag-first is what read as
    /// a glitch on device: SwiftUI lays the key rows out inside the 140pt
    /// Compact frame for one pass, then the frame grows once the new intrinsic
    /// size propagates — a squeeze followed by a jump, in the one direction
    /// where the content is taller than the frame it lands in. Collapsing has
    /// no equivalent problem, which is why only expanding looked wrong.
    func expand() {
        guard keyboardContext.isKeyboardCollapsed else { return }
        pinHeight(to: predictedFullHeight)
        setCollapsed(false)
        releaseHeightOnceLaidOut()
    }

    /// Switches to Compact. Flag first, then shrink: the compact strip is
    /// shorter than either frame, so it never gets squeezed in between.
    func collapse() {
        guard !keyboardContext.isKeyboardCollapsed else { return }
        setCollapsed(true)
        pinHeight(to: Self.compactKeyboardHeight)
    }

    /// What Full will size itself to: KeyboardKit's own key-row arithmetic
    /// plus our toolbar strip. Only has to be right for the frames between
    /// the flag flip and `releaseHeightOnceLaidOut()`, after which the real
    /// intrinsic height takes over — so a few points of drift can't leave the
    /// keyboard clipped.
    private var predictedFullHeight: CGFloat {
        KeyboardLayout.standard(for: keyboardContext).totalHeight + Self.fullToolbarHeight
    }

    /// Hands sizing back to KeyboardKit on the next runloop turn, once the key
    /// rows have had a layout pass at the predicted height.
    private func releaseHeightOnceLaidOut() {
        Task { @MainActor in
            guard !keyboardContext.isKeyboardCollapsed else { return }
            releaseHeight()
        }
    }

    /// Writes the collapse flag with SwiftUI animations off, so the strip and
    /// the key rows swap in a single frame instead of cross-fading against a
    /// frame change the system drives on its own clock.
    private func setCollapsed(_ collapsed: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardContext.isKeyboardCollapsed = collapsed
        }
    }

    private func pinHeight(to constant: CGFloat) {
        guard let inputView else { return }
        UIView.performWithoutAnimation {
            if heightConstraint == nil {
                let constraint = inputView.heightAnchor.constraint(equalToConstant: constant)
                constraint.priority = Self.heightConstraintPriority
                heightConstraint = constraint
            }
            heightConstraint?.constant = constant
            heightConstraint?.isActive = true
            inputView.superview?.layoutIfNeeded()
        }
    }

    private func releaseHeight() {
        UIView.performWithoutAnimation {
            heightConstraint?.isActive = false
        }
    }
}
