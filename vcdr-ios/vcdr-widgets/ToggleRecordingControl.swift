import AppIntents
import SwiftUI
import WidgetKit

struct ToggleRecordingControl: ControlWidget {
    static let kind = "glebglazov.vcdr-ios.vcdr-widgets.ToggleRecordingControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label("Toggle Recording", systemImage: "mic")
            }
        }
        .displayName("Toggle Recording")
        .description("Starts a VCDR recording, or stops the current one and copies the text.")
    }
}
