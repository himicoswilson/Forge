import AppKit
import SwiftUI
import ForgeCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var envChecker = EnvironmentChecker()
    @State private var expanded: [String: Bool] = [:]
    @State private var showAddGroupSheet: Bool = false
    @State private var editingGroup: ServiceGroup?

    private enum GroupSheetMode: Identifiable {
        case add, edit(ServiceGroup)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let g): return "edit-\(g.id)"
            }
        }
    }
    @State private var groupSheet: GroupSheetMode?

    var body: some View {
        List {
            mcpSection
            generalSection
            environmentSection
            projectsSection
            groupsSection
        }
        .listStyle(.inset)
        .frame(minWidth: 440, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Add Project…") { state.addProject() }
            }
        }
        .navigationTitle("Settings")
        .onAppear { if envChecker.checks.isEmpty { envChecker.run() } }
        .sheet(item: $groupSheet) { mode in
            switch mode {
            case .add:
                AddGroupSheet(state: state)
            case .edit(let group):
                EditGroupSheet(state: state, group: group)
            }
        }
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

    // MARK: - Environment

    private var environmentSection: some View {
        Section {
            if envChecker.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking environment…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(envChecker.checks) { check in
                    EnvCheckRow(check: check)
                }
            }
        } header: {
            HStack {
                Text("Environment")
                Spacer()
                Button("Recheck") { envChecker.run() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(envChecker.isChecking)
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
                                project: project.name,
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
    let project: String
    let ignored: Bool
    let onToggle: () -> Void
    @EnvironmentObject var state: AppState

    private var effectiveState: ServiceState {
        let key = ServiceKey(project: project, service: svc.service.name)
        switch state.busyAction[key] {
        case .start, .restart, .hotRestart, .build, .cleanBuild, .startWithBuild: return .starting
        case .stop:                         return .down
        case nil:                           return svc.state
        }
    }

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
            switch effectiveState {
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

// MARK: - Service Groups

extension SettingsView {
    private var groupsSection: some View {
        Section {
            if state.serviceGroups.isEmpty {
                Text("No service groups defined")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.serviceGroups) { group in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        Text(group.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.services.count) services")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { groupSheet = .edit(group) }
                    .contextMenu {
                        Button("Edit…") { groupSheet = .edit(group) }
                        Divider()
                        if let idx = state.serviceGroups.firstIndex(where: { $0.id == group.id }) {
                            if idx > 0 {
                                Button("Move Up") { state.moveGroup(from: IndexSet(integer: idx), to: idx - 1) }
                            }
                            if idx < state.serviceGroups.count - 1 {
                                Button("Move Down") { state.moveGroup(from: IndexSet(integer: idx), to: idx + 2) }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { state.removeGroup(group.id) }
                    }
                }
                .onMove { from, to in
                    state.moveGroup(from: from, to: to)
                }
            }
        } header: {
            HStack {
                Text("Service Groups")
                Spacer()
                Button(action: { groupSheet = .add }) {
                    Image(systemName: "plus")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Add service group")
            }
        }
    }
}

/// Sheet for creating a new service group.
private struct AddGroupSheet: View {
    @ObservedObject var state: AppState
    @State private var name: String = ""
    @State private var projectIndex: Int = 0
    @State private var selectedServices: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var availableServices: [DisplayStatus] {
        guard state.snapshots.indices.contains(projectIndex) else { return [] }
        return state.orderedServices(for: state.snapshots[projectIndex].name)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("New Service Group")
                .font(.headline)
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            if !state.snapshots.isEmpty {
                Picker("Project", selection: $projectIndex) {
                    ForEach(state.snapshots.indices, id: \.self) { i in
                        Text(state.snapshots[i].name).tag(i)
                    }
                }
                .frame(width: 260)
                .onChange(of: projectIndex) { _ in selectedServices.removeAll() }
            }
            if !availableServices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableServices, id: \.service.id) { svc in
                                Toggle(svc.service.name, isOn: Binding(
                                    get: { selectedServices.contains(svc.service.name) },
                                    set: { on in
                                        if on { selectedServices.insert(svc.service.name) }
                                        else { selectedServices.remove(svc.service.name) }
                                    }
                                ))
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .frame(width: 260)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let project = state.snapshots.indices.contains(projectIndex)
                        ? state.snapshots[projectIndex].name : ""
                    var group = ServiceGroup(name: name, project: project)
                    group.services = selectedServices.sorted()
                    state.updateGroup(group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || state.snapshots.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Sheet for editing an existing service group.
private struct EditGroupSheet: View {
    @ObservedObject var state: AppState
    @State private var localGroup: ServiceGroup
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, group: ServiceGroup) {
        self.state = state
        _localGroup = State(initialValue: group)
    }

    private var availableServices: [DisplayStatus] {
        state.orderedServices(for: localGroup.project)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Edit Group")
                .font(.headline)
            TextField("Group name", text: $localGroup.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onChange(of: localGroup.name) { _ in save() }
            HStack {
                Text("Project:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(localGroup.project)
                    .font(.callout)
            }
            .frame(width: 260, alignment: .leading)
            if !availableServices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(availableServices, id: \.service.id) { svc in
                                Toggle(svc.service.name, isOn: Binding(
                                    get: { localGroup.services.contains(svc.service.name) },
                                    set: { on in
                                        if on { localGroup.services.append(svc.service.name) }
                                        else { localGroup.services.removeAll { $0 == svc.service.name } }
                                        save()
                                    }
                                ))
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .frame(width: 260)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        state.updateGroup(localGroup)
    }
}

// MARK: - Environment check row

private extension EnvCheck.Status {
    var systemImage: String {
        switch self {
        case .ok:      "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .ok:      .green
        case .warning: .orange
        case .missing: .red
        }
    }
}

private struct EnvCheckRow: View {
    let check: EnvCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.systemImage)
                .foregroundStyle(check.status.color)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.name)
                    Spacer()
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let hint = check.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
            }
        }
        .padding(.vertical, 1)
    }
}
