import SwiftUI
import ForgeCore

/// Placeholder menu-bar app — M3 (service cards) and M5 (status dot) land here.
@main
struct ForgeApp: App {
    var body: some Scene {
        MenuBarExtra("Forge", systemImage: "hammer.circle.fill") {
            Text("Forge — no project loaded")
            Divider()
            Button("Quit Forge") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
