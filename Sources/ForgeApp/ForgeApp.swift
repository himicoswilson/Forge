import SwiftUI
import ForgeCore
import ForgeMCP

/// Loads the project config and runs the MCP server. GUI milestones
/// (M3 service cards, M5 status dot) build on top of this.
@MainActor
final class AppState: ObservableObject {
    @Published var projectName: String?
    @Published var statusLine = "Starting…"

    private var mcp: ForgeMCPServer?

    init() {
        Task { await bootstrap() }
    }

    /// Project root comes from $FORGE_PROJECT, falling back to the working
    /// directory — both must contain .forge/config.json.
    private func bootstrap() async {
        let env = ProcessInfo.processInfo.environment["FORGE_PROJECT"]
        let root = URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath)

        do {
            let config = try ForgeConfig.load(projectRoot: root)
            let manager = ServiceManager(config: config, projectRoot: root)
            let server = ForgeMCPServer(tools: ForgeTools(manager: manager))
            try await server.start()
            mcp = server
            projectName = config.name
            statusLine = "MCP: http://127.0.0.1:\(ForgeMCPServer.defaultPort)\(ForgeMCPServer.endpoint)"
        } catch ConfigError.notFound {
            statusLine = "No .forge/config.json found — set FORGE_PROJECT"
        } catch {
            statusLine = "MCP failed to start: \(error.localizedDescription)"
        }
    }
}

@main
struct ForgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Forge", systemImage: "hammer.circle.fill") {
            if let project = state.projectName {
                Text("Project: \(project)")
            }
            Text(state.statusLine)
            Divider()
            Button("Quit Forge") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
