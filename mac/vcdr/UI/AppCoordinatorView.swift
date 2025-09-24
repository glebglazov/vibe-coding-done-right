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

    var body: some View {
        MenuBarView()
            .environmentObject(controller)
            .onReceive(controller.$showRecordingOverlay) { isShowing in
                if isShowing {
                    openWindow(id: "recording-overlay")
                }
            }
    }
}
