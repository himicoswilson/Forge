import SwiftUI
import ForgeCore

/// M3 — the main window: service cards grouped by project, with
/// start / stop / restart / hot-restart actions and a log drawer (M4).
struct MainWindowView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(state.snapshots) { project in
                            ProjectSection(project: project)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 620, minHeight: 360)
        .toolbar {
            ToolbarItem {
                Button(action: state.addProject) {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Register a project containing .forge/config.json")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = state.lastError {
                ErrorBar(message: error) { state.lastError = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No projects registered")
                .font(.title3)
            Text("Add a project root containing .forge/config.json")
                .foregroundStyle(.secondary)
            Button("Add Project…", action: state.addProject)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectSection: View {
    let project: ProjectSnapshot
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.headline)
                if let jdk = project.jdk {
                    Text("JDK \(jdk)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text("\(project.upCount)/\(project.services.count) up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Remove from Forge") { state.removeProject(project.name) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help(project.root.path)
            }
            ForEach(project.services, id: \.service.name) { status in
                ServiceCard(project: project.name, status: status)
            }
        }
    }
}

private struct ServiceCard: View {
    let project: String
    let status: ServiceStatus
    @EnvironmentObject var state: AppState
    @State private var showLogs = false

    private var key: ServiceKey { ServiceKey(project: project, service: status.service.name) }
    private var isBusy: Bool { state.busy.contains(key) }

    private var color: Color {
        switch status.state {
        case .up: .green
        case .starting: .yellow
        case .down: Color(nsColor: .tertiaryLabelColor)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(status.service.name)
                    .fontWeight(.medium)
                    .frame(width: 110, alignment: .leading)
                Text(":\(String(status.service.port))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text(status.state.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 64, alignment: .leading)
                Text(status.memoryDescription ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Text(status.uptime ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    actionButtons
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showLogs.toggle() }
                } label: {
                    Image(systemName: showLogs ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Show logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showLogs {
                LogDrawer(project: project, service: status.service)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if status.state == .down {
            Button {
                state.perform(.start, project: project, service: status.service)
            } label: {
                Image(systemName: "play.fill")
            }
            .help("Start")
        } else {
            Button {
                state.perform(.stop, project: project, service: status.service)
            } label: {
                Image(systemName: "stop.fill")
            }
            .help("Stop")
        }
        Button {
            state.perform(.restart, project: project, service: status.service)
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Restart (kill session + relaunch)")
        Button {
            state.perform(.hotRestart, project: project, service: status.service)
        } label: {
            Image(systemName: "bolt.fill")
        }
        .help("Hot restart (recompile module, DevTools reloads)")
    }
}

/// M4 — live tail of the service's tmux pane while expanded.
private struct LogDrawer: View {
    let project: String
    let service: ServiceConfig
    @EnvironmentObject var state: AppState
    @State private var text = "Loading…"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .frame(height: 190)
            .background(Color(nsColor: .textBackgroundColor))
            .task {
                while !Task.isCancelled {
                    text = await state.logs(project: project, service: service)
                    proxy.scrollTo("bottom", anchor: .bottom)
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
    }
}

private struct ErrorBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(10)
        .background(.bar)
    }
}
