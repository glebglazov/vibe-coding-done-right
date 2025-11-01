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
            .onReceive(controller.$showResultsOverlay) { showResults in
                print("📡 AppCoordinatorView: Received showResultsOverlay change: \(showResults)")

                // Only respond to changes after the view has appeared
                guard hasAppeared else {
                    print("⏸️ AppCoordinatorView: Ignoring change - view hasn't appeared yet")
                    return
                }

                if showResults {
                    print("🪟 AppCoordinatorView: Opening results overlay window")
                    openWindow(id: "results-overlay")
                } else {
                    print("🫥 AppCoordinatorView: Results overlay hidden")
                }
            }
    }
}
