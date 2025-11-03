//
//  HUDCoordinator.swift
//  vcdr
//
//  Created by Claude Code
//

import SwiftUI

/// Coordinates HUD window opening/closing with the menu bar view
struct HUDCoordinator: View {
    @ObservedObject var hudManager: HUDNotificationManager
    @ObservedObject var menuBarController: MenuBarController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AppCoordinatorView()
            .environmentObject(menuBarController)
            .onAppear {
                // Inject hudManager after initialization
                menuBarController.hudManager = hudManager

                // Inject openWindow callback
                menuBarController.openWindowCallback = { windowId in
                    openWindow(id: windowId)
                }

                // Open mini overlay window on startup (it will show/hide based on isOverlayVisible)
                openWindow(id: "mini-overlay")
            }
            .onChange(of: hudManager.shouldShowWindow) { _, newValue in
                if newValue {
                    openWindow(id: "hud-notification")
                }
            }
    }
}
