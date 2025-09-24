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
            .onReceive(controller.$isRecording) { isRecording in
                print("📡 AppCoordinatorView: Received isRecording change: \(isRecording)")

                // Only respond to changes after the view has appeared
                guard hasAppeared else {
                    print("⏸️ AppCoordinatorView: Ignoring change - view hasn't appeared yet")
                    return
                }

                if isRecording {
                    print("🪟 AppCoordinatorView: Opening recording overlay window")
                    openWindow(id: "recording-overlay")
                } else {
                    print("🫥 AppCoordinatorView: Recording stopped - overlay should hide")
                }
                // Don't dismiss - let window content handle visibility
            }
    }
}
