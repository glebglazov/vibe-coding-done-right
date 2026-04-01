/// Builds a mode label string like "Mode · params · dest symbol" from components.
///
/// Used by CaptureViewModel, RecordingIndicatorView, MenuBarView, and HomeTabView
/// to display the active mode with its parameters and output destination.
func buildModeLabel(
    modeName: String,
    parameterLabels: String?,
    destinationSymbol: String
) -> String {
    [modeName, parameterLabels, destinationSymbol].compactMap { $0 }.joined(separator: " · ")
}
