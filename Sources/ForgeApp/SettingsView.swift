import AppKit
import SwiftUI
import ForgeCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        List {
            mcpSection
            generalSection
            projectsSection
        }
        .listStyle(.inset)
        .frame(minWidth: 440, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Add Project…") { state.addProject() }
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - MCP Server

    private var mcpSection: some View {
        Section("MCP Server") {
            HStack(spacing: 10) {
                Circle()
                    .fill(state.mcpPort != nil ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                if let port = state.mcpPort {
                    Text("Listening on :" + String(port))
                } else {
                    Text("Not running")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Config") { state.copyMCPConfig() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.mcpPort == nil)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle(isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            )) {
                Text("Launch at Login")
            }
        }
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        if state.snapshots.isEmpty {
            Section("Projects") {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No Projects")
                            .font(.headline)
                        Text("Click \"Add Project\u{2026}\" to get started.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            }
        } else {
            ForEach(state.snapshots) { project in
                let services = state.orderedServices(for: project.name)
                let isExpanded = Binding(
                    get: { expanded[project.name] ?? true },
                    set: { expanded[project.name] = $0 }
                )
                Section {
                    DisclosureGroup(isExpanded: isExpanded) {
                        ForEach(services, id: \.service.id) { svc in
                            ServiceRow(
                                svc: svc,
                                ignored: state.isIgnored(
                                    project: project.name,
                                    service: svc.service.name
                                )
                            ) {
                                state.toggleIgnore(
                                    project: project.name,
                                    service: svc.service.name
                                )
                            }
                        }
                        .onMove { from, to in
                            state.moveService(in: project.name, from: from, to: to)
                        }
                    } label: {
                        ProjectLabel(
                            project: project,
                            serviceCount: services.count,
                            isExpanded: isExpanded.wrappedValue
                        ) {
                            state.removeProject(project.name)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Project label (DisclosureGroup header)

private struct ProjectLabel: View {
    let project: ProjectSnapshot
    let serviceCount: Int
    let isExpanded: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .font(.headline)
                .foregroundStyle(.primary)
            if let jdk = project.jdk {
                Text("JDK \(jdk)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        .secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            if !isExpanded {
                Text("\(serviceCount) services")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.quaternary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Service row

private struct ServiceRow: View {
    let svc: DisplayStatus
    let ignored: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            dotView
            HStack(spacing: 5) {
                Text(svc.service.name)
                    .foregroundStyle(ignored ? .secondary : .primary)
                Text(":" + String(svc.service.port))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospaced()
            }
            Spacer()
            Button(action: onToggle) {
                Image(systemName: ignored ? "eye.slash" : "eye")
                    .foregroundStyle(ignored ? .tertiary : .secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(ignored ? "Show in menu" : "Hide from menu")
        }
        .padding(.vertical, 1)
        .opacity(ignored ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var dotView: some View {
        ZStack {
            switch svc.state {
            case .up:
                Circle().fill(Color.green).frame(width: 8, height: 8)
            case .starting:
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
            case .down:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
    }
}
