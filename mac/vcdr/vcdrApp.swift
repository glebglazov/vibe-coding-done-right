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


        Window("Recording", id: "recording-overlay") {
            ZStack {
                if menuBarController.isRecording {
                    RecordingOverlay(
                        onStopAndSendToClipboard: {
                            menuBarController.stopAndSendToClipboard()
                        },
                        onStopAndSendToTmux: {
                            menuBarController.stopAndSendToTmux()
                        },
                        onCancel: {
                            menuBarController.cancelRecording()
                        },
                        audioRecorder: menuBarController.audioRecorder
                    )
                    .onAppear {
                        print("👁️ RecordingOverlay: Appeared - should be visible")
                    }
                    .onDisappear {
                        print("👻 RecordingOverlay: Disappeared - should be hidden")
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
                if let window = NSApp.windows.first(where: { $0.title == "Recording" }) {
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
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Stop and Send to Clipboard") {
                    menuBarController.stopAndSendToClipboard()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Stop and Send to Tmux") {
                    menuBarController.stopAndSendToTmux()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Cancel Recording") {
                    menuBarController.cancelRecording()
                }
                .keyboardShortcut(.escape)
            }
        }
    }
}
