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
            MenuBarView()
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
    }
}
