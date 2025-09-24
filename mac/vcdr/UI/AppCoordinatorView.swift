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
            .onReceive(controller.$showRecordingOverlay) { isShowing in
                // Only respond to changes after the view has appeared
                guard hasAppeared else { return }

                if isShowing {
                    openWindow(id: "recording-overlay")
                }
                // Don't dismiss - let window content handle visibility
            }
    }
}
