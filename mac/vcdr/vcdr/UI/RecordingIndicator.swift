import AppKit
import SwiftUI

final class RecordingIndicatorPanel {
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: RecordingIndicatorView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 48, height: 48)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        // Position at top center of the main screen, just below the menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y
            let x = screenFrame.midX - 24
            let y = screenFrame.maxY - menuBarHeight - 56
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}

private struct RecordingIndicatorView: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)

            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animating)
        }
        .onAppear { animating = true }
    }
}
