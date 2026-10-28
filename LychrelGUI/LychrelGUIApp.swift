//
//  LychrelGUIApp.swift
//  LychrelGUI
//
//  Created by Peter Whysall on 14/10/2026.
//

import SwiftUI

@main
struct LychrelGUIApp: App {
    var body: some Scene {
        Window("Lychrel", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
