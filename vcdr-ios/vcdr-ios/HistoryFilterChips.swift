import SwiftUI

/// ALL and DISCARDED · N, above the history list.
struct HistoryFilterChips: View {
    // MARK: - Constants

    private static let fontSize: CGFloat = 10
    private static let tracking: CGFloat = 2
    private static let height: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12
    private static let border: CGFloat = 1.5
    private static let spacing: CGFloat = 8
    private static let rowPadding: CGFloat = 16

    let filter: HistoryFilter
    let discardedCount: Int
    let theme: Theme
    let onSelect: (HistoryFilter) -> Void

    var body: some View {
        HStack(spacing: Self.spacing) {
            chip("ALL", for: .all)
            chip("DISCARDED · \(discardedCount)", for: .discarded)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.rowPadding)
        .padding(.vertical, Self.spacing)
    }

    private func chip(_ title: String, for value: HistoryFilter) -> some View {
        let isOn = filter == value
        return Button {
            onSelect(value)
        } label: {
            Text(title)
                .font(.system(size: Self.fontSize, weight: .bold))
                .tracking(Self.tracking)
                .foregroundStyle(isOn ? theme.surfaceLowest : theme.onSurfaceVariant)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(height: Self.height)
                .background(Capsule().fill(isOn ? theme.onSurface : Color.clear))
                .overlay(Capsule().stroke(isOn ? theme.onSurface : theme.onSurfaceVariant, lineWidth: Self.border))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
