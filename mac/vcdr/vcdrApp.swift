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
        
        Window("VCDR Settings", id: "settings") {
            SettingsView()
                .environmentObject(menuBarController)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 300)
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
        
        
        Window("Capturing", id: "capturing-overlay") {
            ZStack {
                if menuBarController.isOverlayVisible {
                    CapturingOverlay(
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
                        onToggleRecording: {
                            menuBarController.toggleRecordingInOverlay()
                        },
                        audioRecorder: menuBarController.audioRecorder,
                        controller: menuBarController,
                        previousActiveApp: menuBarController.previousActiveApp
                    )
                    .onAppear {
                        print("👁️ CapturingOverlay: Appeared - should be visible")
                    }
                    .onDisappear {
                        print("👻 CapturingOverlay: Disappeared - should be hidden")
                    }
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .onAppear {
                            print("🫥 Transparent view: Appeared - overlay should be hidden")
                        }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .task {
                // Configure window styling once when created
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                if let window = NSApp.windows.first(where: { $0.title == "Capturing" }) {
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
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.bottomTrailing)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Toggle Recording") {
                    menuBarController.toggleRecordingInOverlay()
                }
                .keyboardShortcut("r", modifiers: [])

                Divider()

                Button("Copy to clipboard") {
                    menuBarController.stopAndCopyToClipboard()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste into current program") {
                    menuBarController.stopAndPaste()
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("Stop and Send to Tmux") {
                    menuBarController.stopAndSendToTmux()
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("Switch to Disabled mode") {
                    menuBarController.switchToDisabledMode()
                }
                .keyboardShortcut("x", modifiers: [])

                Button("Switch to Assistant mode") {
                    menuBarController.switchToAssistantMode()
                }
                .keyboardShortcut("a", modifiers: [])

                Button("Cycle Custom Modes") {
                    menuBarController.cycleCustomModes()
                }
                .keyboardShortcut("c", modifiers: [])

                Divider()

                Button("Cancel Recording") {
                    menuBarController.cancelRecording()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
