import AppKit
import SwiftUI
import ForgeCore
import ForgeMCP

/// Owns the multi-project workspace and the MCP server. GUI milestones
/// (M3 service cards, M5 status dot) build on top of this.
@MainActor
final class AppState: ObservableObject {
    @Published var projectNames: [String] = []
    @Published var statusLine = "Starting…"

    private let workspace = Workspace()
    private var mcp: ForgeMCPServer?

    init() {
        Task { await bootstrap() }
    }

    /// Registered projects come from ~/.forge/projects.json; $FORGE_PROJECT
    /// (if set) is added for this session without being persisted.
    private func bootstrap() async {
        for root in ProjectRegistry.load() {
            _ = try? await workspace.addProject(root: root)
        }
        if let env = ProcessInfo.processInfo.environment["FORGE_PROJECT"] {
            _ = try? await workspace.addProject(root: URL(fileURLWithPath: env))
        }
        await refresh()

        let server = ForgeMCPServer(tools: ForgeTools(workspace: workspace))
        do {
            try await server.start()
            mcp = server
            statusLine = "MCP: http://127.0.0.1:\(ForgeMCPServer.defaultPort)\(ForgeMCPServer.endpoint)"
        } catch {
            statusLine = "MCP failed to start: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        let projects = await workspace.projects
        projectNames = projects.map(\.config.name)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project root containing .forge/config.json"
        guard panel.runModal() == .OK, let root = panel.url else { return }

        Task {
            do {
                try await workspace.addProject(root: root)
                try ProjectRegistry.save(await workspace.roots)
                await refresh()
            } catch ConfigError.notFound {
                statusLine = "No .forge/config.json in \(root.lastPathComponent)"
            } catch {
                statusLine = "Could not add project: \(error.localizedDescription)"
            }
        }
    }

    func removeProject(_ name: String) {
        Task {
            await workspace.removeProject(named: name)
            try? ProjectRegistry.save(await workspace.roots)
            await refresh()
        }
    }
}

@main
struct ForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Forge", systemImage: "hammer.circle.fill") {
            if state.projectNames.isEmpty {
                Text("No projects registered")
            } else {
                ForEach(state.projectNames, id: \.self) { name in
                    Menu(name) {
                        Button("Remove") { state.removeProject(name) }
                    }
                }
            }
            Divider()
            Button("Add Project…") { state.addProject() }
            Text(state.statusLine)
            Divider()
            Button("Quit Forge") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
