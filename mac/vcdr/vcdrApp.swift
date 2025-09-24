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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = NSApp.windows.first(where: { $0.title == "Recording" }) {
                        // Make window movable by dragging anywhere
                        window.isMovableByWindowBackground = true

                        // Make window truly borderless
                        window.styleMask.insert(.borderless)
                        window.styleMask.remove(.titled)
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden

                        // Add rounded corners to both window and content
                        window.backgroundColor = NSColor.clear
                        window.isOpaque = false

                        window.contentView?.wantsLayer = true
                        window.contentView?.layer?.cornerRadius = 16
                        window.contentView?.layer?.masksToBounds = true

                        // Focus the window
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.center)
    }
}
