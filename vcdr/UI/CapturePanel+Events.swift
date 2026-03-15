import AppKit
import OSLog

extension CapturePanel {

    static let focusMaxAttempts = 10
    static let focusRetryDelay: Duration = .milliseconds(10)

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
        ) { [weak self, weak hostingView, weak panel] _ in
            guard let self else { return }
            if self.viewModel?.isMinimized == true {
                guard self.viewModel?.isRecording != true else { return }
                self.onPillClicked?()
                return
            }
            guard let hostingView, let panel else { return }
            if self.viewModel?.isRecording != true {
                self.focusActiveTextView(in: hostingView, panel: panel)
            }
        }

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isLockedForFollowUp else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isLockedForFollowUp else { return }
            guard self.viewModel?.modeSwitcherViewModel == nil else { return }
            guard self.viewModel?.isMinimized != true else { return }
            self.onFocusLost?()
        }
    }

    /// Focuses the NSTextView corresponding to `activeSegmentIndex`, falling back
    /// to the first text view if the target index is out of bounds.
    func focusActiveTextView(in view: NSView, panel: NSPanel, cursorAtEnd: Bool = false) {
        let targetIndex = viewModel?.activeSegmentIndex ?? 0
        Task { @MainActor in
            for _ in 0..<Self.focusMaxAttempts {
                let textViews = Self.findAllTextViews(in: view)
                let index = min(targetIndex, textViews.count - 1)
                if index >= 0, index < textViews.count {
                    let textView = textViews[index]
                    panel.makeFirstResponder(textView)
                    if panel.firstResponder === textView {
                        if cursorAtEnd {
                            let length = (textView.string as NSString).length
                            textView.setSelectedRange(NSRange(location: length, length: 0))
                        }
                        return
                    }
                }
                try? await Task.sleep(for: Self.focusRetryDelay)
            }
            Logger.ui.warning("Capture panel: failed to focus text view at index \(targetIndex) after \(Self.focusMaxAttempts) attempts")
        }
    }

    private static func findAllTextViews(in view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        collectTextViews(in: view, into: &result)
        return result
    }

    private static func collectTextViews(in view: NSView, into result: inout [NSTextView]) {
        if let textView = view as? NSTextView {
            result.append(textView)
            return
        }
        for subview in view.subviews {
            collectTextViews(in: subview, into: &result)
        }
    }
}
