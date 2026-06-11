import AppKit
import SwiftUI
import ForgeCore

@main
struct ForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Forge", id: "main") {
            MainWindowView()
                .environmentObject(state)
        }
        .defaultSize(width: 680, height: 440)

        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
    }
}

/// M5 — menu-bar dot coloured by the aggregate state of all services.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.icon(for: state.aggregate))
            .task {
                if ProcessInfo.processInfo.environment["FORGE_SHOW_WINDOW"] == "1" {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    static func icon(for aggregate: AggregateState) -> NSImage {
        let color: NSColor =
            switch aggregate {
            case .allUp: .systemGreen
            case .partial: .systemYellow
            case .allDown: .systemRed
            case .empty: .tertiaryLabelColor
            }
        let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Forge")!
        let configured = symbol.withSymbolConfiguration(
            .init(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [color]))
        ) ?? symbol
        configured.isTemplate = false
        return configured
    }
}

private struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.snapshots.isEmpty {
            Text("No projects registered")
        } else {
            ForEach(state.snapshots) { project in
                Text("\(project.name): \(project.upCount)/\(project.services.count) up")
            }
        }
        Divider()
        Button("Open Forge") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("f")
        Button("Add Project…") { state.addProject() }
        Divider()
        Text(state.statusLine)
        Divider()
        Button("Quit Forge") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
