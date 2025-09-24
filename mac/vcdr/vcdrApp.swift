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
