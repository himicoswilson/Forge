import AppKit
import SwiftUI
import ForgeCore

@main
struct ForgeApp: App {
    @StateObject private var state = AppState()

    init() {
        if let url = Bundle.module.url(
            forResource: "1024", withExtension: "png",
            subdirectory: "Assets.xcassets/AppIcon.appiconset"
        ), let img = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = img
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Image(nsImage: ForgeIcon.image)
        }
        .menuBarExtraStyle(.menu)

        Window("Forge Settings", id: "settings") {
            SettingsView()
                .environmentObject(state)
        }
        .defaultSize(width: 440, height: 520)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Menu bar icon

private enum ForgeIcon {
    @MainActor static let image: NSImage = {
        if let url = Bundle.module.url(
            forResource: "StatusBarIcon", withExtension: "svg",
            subdirectory: "Assets.xcassets/StatusBarIcon.imageset"
        ), let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        // Fallback: code-drawn hammer
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 6), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 7, width: 6, height: 10), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

// MARK: - State dot (NSImage, not Canvas — Canvas silently drops in .menu style)

extension ServiceState {
    var dotImage: NSImage {
        let size = NSSize(width: 9, height: 9)
        let img = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(x: 0.5, y: 0.5, width: 8, height: 8)
            switch self {
            case .up:
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .starting:
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .down:
                NSColor.tertiaryLabelColor.setStroke()
                let path = NSBezierPath(ovalIn: rect)
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Menu

private struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.snapshots.isEmpty {
            Text("No projects registered")
        } else {
            ForEach(state.snapshots) { project in
                let active = state.orderedServices(for: project.name)
                    .filter { !state.isIgnored(project: project.name, service: $0.service.name) }
                Section(project.name) {
                    Button("Start All") { state.startAll(project: project.name) }
                        .disabled(!active.contains { $0.state == .down })
                    Button("Stop All") { state.stopAll(project: project.name) }
                        .disabled(!active.contains { $0.state != .down })
                    Divider()
                    ForEach(active, id: \.service.id) { status in
                        ServiceMenuView(status: status, project: project.name)
                            .environmentObject(state)
                    }
                }
            }
        }

        Divider()
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Button("Add Project…") { state.addProject() }
        Divider()
        Button("Quit Forge") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct ServiceMenuView: View {
    let status: DisplayStatus
    let project: String
    @EnvironmentObject var state: AppState

    var body: some View {
        let key = ServiceKey(project: project, service: status.service.name)
        let dotState = effectiveDotState(for: key)
        Menu {
            Text(stateLabel(dotState))
            Divider()
            if status.state == .down {
                Button("Start") {
                    state.perform(.start, project: project, service: status.service)
                }
            } else {
                Button("Stop") {
                    state.perform(.stop, project: project, service: status.service)
                }
                Divider()
                Button("Restart") {
                    state.perform(.restart, project: project, service: status.service)
                }
                Button("Hot Restart") {
                    state.perform(.hotRestart, project: project, service: status.service)
                }
            }
            if status.logExists {
                Divider()
                Button("View Logs") {
                    state.openLogs(project: project, service: status.service)
                }
            }
        } label: {
            Label {
                Text(status.service.name)
            } icon: {
                Image(nsImage: dotState.dotImage)
            }
        }
    }

    /// While an action is in-flight the dot shows the expected transitional
    /// state immediately, without waiting for the next poll cycle.
    private func effectiveDotState(for key: ServiceKey) -> ServiceState {
        switch state.busyAction[key] {
        case .start, .restart, .hotRestart: return .starting
        case .stop:                         return .down
        case nil:                           return status.state
        }
    }

    private func stateLabel(_ s: ServiceState) -> String {
        switch s {
        case .up:       "UP — :\(status.service.port)"
        case .starting: "STARTING…"
        case .down:     "DOWN"
        }
    }
}


