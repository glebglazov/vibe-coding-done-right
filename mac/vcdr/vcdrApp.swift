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

        // Capture input window
        Window("Captured Input", id: "capture-preview") {
            CaptureInputWindow(
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
                if let window = await WindowHelper.waitForWindow(titled: "HUD") {
                    window.styleMask = [.borderless, .fullSizeContentView]
                    window.backgroundColor = .clear
                    window.isOpaque = false
                    window.level = .statusBar
                    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                    window.isMovable = false
                    window.ignoresMouseEvents = true

                    // Center on active screen
                    ScreenHelper.centerWindow(window)
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
                        onAddLastClipboard: {
                            menuBarController.addClipboardToCapture()
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
                if let window = await WindowHelper.waitForWindow(titled: "Mini Overlay") {
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

                    // Position in bottom center with margin on the active screen
                    ScreenHelper.positionWindowAtBottom(panel, margin: 80, relativeTo: menuBarController.previousActiveApp)

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
                onStopAndPreview: {
                    menuBarController.stopAndPreview()
                },
                onCancel: {
                    menuBarController.cancelRecording()
                },
                controller: menuBarController,
                previousActiveApp: menuBarController.previousActiveApp
            )
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
                }
            }
            .onChange(of: menuBarController.showResultsOverlay) { _, newValue in
                if newValue {
                    // When results overlay shows, reposition, activate and focus it
                    Task {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                        if let window = NSApp.windows.first(where: { $0.title == "Results" }) {
                            // Reposition to center of active screen
                            ScreenHelper.centerWindow(window, relativeTo: menuBarController.previousActiveApp)

                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                } else {
                    // Close the window when overlay should be hidden
                    Task {
                        if let window = NSApp.windows.first(where: { $0.title == "Results" }) {
                            window.close()
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

        // Processed output window
        Window("Processed Output", id: "preview-window") {
            if menuBarController.showPreviewWindow {
                ProcessedOutputWindow(
                    text: menuBarController.previewText,
                    isPresented: $menuBarController.showPreviewWindow
                )
            } else {
                Color.clear
                    .frame(width: 600, height: 400)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 400)
        .windowLevel(.floating)

        // History window
        Window("Capture History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 900, height: 700)
    }
}
