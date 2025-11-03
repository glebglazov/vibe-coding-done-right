//
//  vcdrApp.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI

@main
struct vcdrApp: App {
    @StateObject private var menuBarController = MenuBarController()
    @StateObject private var hudManager = HUDNotificationManager()

    init() {
        // Inject hudManager into menuBarController
        // Note: This happens before StateObject initialization, so we use a workaround
    }

    var body: some Scene {
        MenuBarExtra("VCDR", systemImage: menuBarController.menuBarIcon) {
            HUDCoordinator(hudManager: hudManager, menuBarController: menuBarController)
        }
        .menuBarExtraStyle(.menu)
        
        Window("vcdr settings", id: "settings") {
            SettingsView()
                .environmentObject(menuBarController)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 300)
        .windowLevel(.floating)

        // Capture actions preview window
        Window("Capture Preview", id: "capture-preview") {
            CaptureActionsPreview(
                actions: menuBarController.captureActions,
                title: "Current Capture"
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 400)
        .windowLevel(.floating)

        // Transient HUD notification window
        Window("HUD", id: "hud-notification") {
            ZStack {
                if let notification = hudManager.currentNotification {
                    TransientHUD(
                        icon: notification.icon,
                        iconColor: notification.iconColor,
                        title: notification.title,
                        subtitle: notification.subtitle,
                        isVisible: hudManager.isVisible
                    )
                } else {
                    Color.clear
                        .frame(width: 280, height: 50)
                }
            }
            .frame(width: 280, height: 50)
            .ignoresSafeArea()
            .task {
                // Configure HUD window styling
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let window = NSApp.windows.first(where: { $0.title == "HUD" }) {
                    window.styleMask = [.borderless, .fullSizeContentView]
                    window.backgroundColor = .clear
                    window.isOpaque = false
                    window.level = .statusBar
                    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                    window.isMovable = false
                    window.ignoresMouseEvents = true

                    // Center on screen
                    if let screen = NSScreen.main {
                        let screenFrame = screen.frame
                        let windowSize = CGSize(width: 280, height: 50)
                        let origin = CGPoint(
                            x: screenFrame.midX - windowSize.width / 2,
                            y: screenFrame.midY - windowSize.height / 2
                        )
                        window.setFrame(CGRect(origin: origin, size: windowSize), display: true)
                    }
                }
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 280, height: 50)

        // Mini overlay (always-visible status indicator during capture)
        Window("Mini Overlay", id: "mini-overlay") {
            ZStack {
                if menuBarController.isCapturing {
                    MiniOverlay(
                        isRecording: menuBarController.isRecording,
                        audioRecorder: menuBarController.audioRecorder,
                        controller: menuBarController,
                        onToggleRecording: {
                            menuBarController.toggleRecordingInOverlay()
                        },
                        onAddClipboard: {
                            menuBarController.copySelectionAndAddToCapture()
                        },
                        onAddKeyboardInput: {
                            menuBarController.openKeyboardInputOverlay()
                        },
                        onPreview: {
                            menuBarController.openPreview()
                        },
                        onStopCapture: {
                            menuBarController.toggleCapture()
                        }
                    )
                } else {
                    Color.clear
                        .frame(width: 260, height: 42)
                }
            }
            .frame(width: 260, height: 42)
            .ignoresSafeArea()
            .task {
                // Configure mini overlay window styling
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let window = NSApp.windows.first(where: { $0.title == "Mini Overlay" }) {
                    // Replace the window with our custom non-activating panel
                    let panel = NonActivatingPanel(
                        contentRect: window.frame,
                        styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false
                    )

                    // Transfer content view
                    panel.contentView = window.contentView

                    // Configure panel properties
                    panel.backgroundColor = .clear
                    panel.isOpaque = false
                    panel.level = .statusBar
                    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                    panel.isMovable = false
                    panel.hidesOnDeactivate = false

                    // Position in bottom center with margin
                    if let screen = NSScreen.main {
                        let screenFrame = screen.frame
                        let windowSize = CGSize(width: 260, height: 42)
                        let margin: CGFloat = 80
                        let origin = CGPoint(
                            x: screenFrame.midX - windowSize.width / 2,
                            y: screenFrame.minY + margin
                        )
                        panel.setFrame(CGRect(origin: origin, size: windowSize), display: true)
                    }

                    // Close the old window and show the panel
                    window.close()
                    panel.orderFront(nil)
                }
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 260, height: 42)
        

        Window("Results", id: "results-overlay") {
            ZStack {
                if menuBarController.showResultsOverlay {
                    ResultsOverlay(
                        onStopAndPaste: {
                            menuBarController.stopAndPaste()
                        },
                        onStopAndCopyToClipboard: {
                            menuBarController.stopAndCopyToClipboard()
                        },
                        onStopAndSendToTmux: {
                            menuBarController.stopAndSendToTmux()
                        },
                        onCancel: {
                            menuBarController.cancelRecording()
                        },
                        controller: menuBarController,
                        previousActiveApp: menuBarController.previousActiveApp
                    )
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .opacity(0)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .task {
                // Configure window styling once when created - do this immediately
                if let window = NSApp.windows.first(where: { $0.title == "Results" }) {
                    window.isMovableByWindowBackground = true
                    window.styleMask.insert(.borderless)
                    window.styleMask.remove(.titled)
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.backgroundColor = NSColor.clear
                    window.isOpaque = false
                    window.contentView?.wantsLayer = true
                    window.contentView?.layer?.cornerRadius = 16
                    window.contentView?.layer?.masksToBounds = true
                    window.acceptsMouseMovedEvents = true
                    window.level = .floating
                    window.collectionBehavior = [.moveToActiveSpace]

                    // Center on screen immediately
                    if let screen = NSScreen.main {
                        let screenFrame = screen.frame
                        let windowSize = window.frame.size
                        let origin = CGPoint(
                            x: screenFrame.midX - windowSize.width / 2,
                            y: screenFrame.midY - windowSize.height / 2
                        )
                        window.setFrameOrigin(origin)
                    }
                }
            }
            .onChange(of: menuBarController.showResultsOverlay) { _, newValue in
                if newValue {
                    // When results overlay shows, activate and focus it
                    Task {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                        if let window = NSApp.windows.first(where: { $0.title == "Results" }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        // Keyboard input window
        Window("Add Keyboard Input", id: "keyboard-input-overlay") {
            KeyboardInputOverlay(
                isPresented: $menuBarController.showKeyboardInputOverlay,
                onSubmit: { text in
                    menuBarController.addKeyboardInput(text: text)
                }
            )
            .frame(width: 320, height: 160)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 160)
        .windowLevel(.floating)
    }
}
