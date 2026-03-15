import SwiftUI

/// ViewModifier that focuses a field and selects all text on appear.
/// Used by detail views (ModeDetailView, OutputDestinationDetailView) to
/// auto-select the name field when navigating to a new item.
struct SelectAllOnAppear: ViewModifier {
    // MARK: - Constants

    /// Delay for NSTextField first responder to settle after SwiftUI focus state
    /// change, otherwise selectAll is a no-op.
    private static let selectAllDelay: Duration = .milliseconds(100)

    var focusState: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.onAppear {
            focusState.wrappedValue = true
            Task { @MainActor in
                try? await Task.sleep(for: Self.selectAllDelay)
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}
