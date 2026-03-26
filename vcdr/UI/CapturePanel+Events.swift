import AppKit
import OSLog

extension CapturePanel {

    func setupEventMonitors(panel: NSPanel, hostingView: NSView) {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel, weak panel] event in
            guard let viewModel, panel?.isKeyWindow == true else { return event }
            if viewModel.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Ignore clicks on the minimized pill during recording/processing
            guard self.viewModel?.isMinimized != true else { return }
        }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.viewModel?.isSuspendedForModeSwitcher != true else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _
            in
            guard let self else { return }
            guard self.viewModel?.isSuspendedForModeSwitcher != true else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }
    }
}
