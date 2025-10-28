//
//  AppCoordinatorView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI

struct AppCoordinatorView: View {
    @EnvironmentObject var controller: MenuBarController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hasAppeared = false

    var body: some View {
        MenuBarView()
            .environmentObject(controller)
            .onAppear {
                hasAppeared = true
            }
            .onReceive(controller.$isOverlayVisible) { isOverlayVisible in
                print("📡 AppCoordinatorView: Received isOverlayVisible change: \(isOverlayVisible)")

                // Only respond to changes after the view has appeared
                guard hasAppeared else {
                    print("⏸️ AppCoordinatorView: Ignoring change - view hasn't appeared yet")
                    return
                }

                if isOverlayVisible {
                    print("🪟 AppCoordinatorView: Opening capturing overlay window")
                    openWindow(id: "capturing-overlay")
                } else {
                    print("🫥 AppCoordinatorView: Overlay hidden")
                }
                // Don't dismiss - let window content handle visibility
            }
    }
}
