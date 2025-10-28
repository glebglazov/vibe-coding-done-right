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

    var body: some Scene {
        MenuBarExtra("VCDR", systemImage: "mic") {
            AppCoordinatorView()
                .environmentObject(menuBarController)
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
