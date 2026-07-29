import Combine
import KeyboardKit
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

    /// Height the keyboard claims in Compact — roughly half of Full's ~290pt.
    static let compactKeyboardHeight: CGFloat = 140

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
    /// to persistence + height. Call once from `viewDidLoad`, before the
    /// first frame, so the keyboard opens in the right state and size.
    func activate() {
        keyboardContext.isKeyboardCollapsed = KeyboardDisplayModeStore.current() == .compact
        keyboardContext.$isKeyboardCollapsed
            .removeDuplicates()
            .sink { [weak self] collapsed in
                KeyboardDisplayModeStore.set(collapsed ? .compact : .full)
                self?.applyHeight(collapsed: collapsed)
            }
            .store(in: &cancellables)
    }

    /// Re-asserts the height constraint on each appearance — the system can
    /// drop or override view constraints between appearances.
    func reassertHeight() {
        applyHeight(collapsed: keyboardContext.isKeyboardCollapsed)
    }

    /// Switches to Full: the already-built key rows return instantly.
    func expand() {
        keyboardContext.isKeyboardCollapsed = false
    }

    /// Switches to Compact.
    func collapse() {
        keyboardContext.isKeyboardCollapsed = true
    }

    private func applyHeight(collapsed: Bool) {
        guard let inputView else { return }
        if collapsed {
            if heightConstraint == nil {
                let constraint = inputView.heightAnchor
                    .constraint(equalToConstant: Self.compactKeyboardHeight)
                constraint.priority = Self.heightConstraintPriority
                heightConstraint = constraint
            }
            heightConstraint?.isActive = true
        } else {
            heightConstraint?.isActive = false
        }
    }
}
