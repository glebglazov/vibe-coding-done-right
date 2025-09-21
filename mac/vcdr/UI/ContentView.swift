//
//  ContentView.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "mic.circle")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("VCDR runs in the menu bar")
                .font(.caption)
        }
        .padding()
        .frame(width: 200, height: 100)
    }
}

#Preview {
    ContentView()
}
