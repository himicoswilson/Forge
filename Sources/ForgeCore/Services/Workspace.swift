import Foundation

/// All projects Forge currently manages — one `ServiceManager` per project,
/// addressable by project name, with service-name resolution across projects.
public actor Workspace {
    public enum ResolutionError: Error, Equatable {
        case noProjects
        case unknownProject(String, known: [String])
        case unknownService(String, available: [String])
        case ambiguousService(String, projects: [String])
    }

    private let runner: any CommandRunning
    public private(set) var projects: [ServiceManager] = []

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// Loads `<root>/.forge/config.json` and registers the project.
    /// Re-adding the same root replaces the previous registration (reload).
    @discardableResult
    public func addProject(root: URL) throws -> ServiceManager {
        let config = try ForgeConfig.load(projectRoot: root)
        let manager = ServiceManager(config: config, projectRoot: root, runner: runner)
        projects.removeAll { $0.projectRoot.standardizedFileURL == root.standardizedFileURL }
        projects.append(manager)
        return manager
    }

    /// Registers an already-built manager (used by tests).
    public func register(_ manager: ServiceManager) {
        projects.removeAll { $0.projectRoot == manager.projectRoot }
        projects.append(manager)
    }

    public func removeProject(named name: String) {
        projects.removeAll { $0.config.name == name }
    }

    public var roots: [URL] {
        projects.map(\.projectRoot)
    }

    public func project(named name: String) -> ServiceManager? {
        projects.first { $0.config.name == name }
    }

    /// Finds a service by name. `project` is only required when the same
    /// service name exists in more than one registered project.
    public func resolve(service name: String, project: String? = nil) throws -> (manager: ServiceManager, service: ServiceConfig) {
        try Self.resolve(in: projects, service: name, project: project)
    }

    /// Pure resolution over a snapshot, callable off the actor.
    public static func resolve(
        in projects: [ServiceManager],
        service name: String,
        project: String? = nil
    ) throws -> (manager: ServiceManager, service: ServiceConfig) {
        guard !projects.isEmpty else { throw ResolutionError.noProjects }

        if let project {
            guard let manager = projects.first(where: { $0.config.name == project }) else {
                throw ResolutionError.unknownProject(project, known: projects.map(\.config.name))
            }
            guard let service = manager.config.service(named: name) else {
                throw ResolutionError.unknownService(name, available: manager.config.services.map { "\(project)/\($0.name)" })
            }
            return (manager, service)
        }

        let matches = projects.compactMap { manager in
            manager.config.service(named: name).map { (manager, $0) }
        }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            let available = projects.flatMap { manager in
                manager.config.services.map { "\(manager.config.name)/\($0.name)" }
            }
            throw ResolutionError.unknownService(name, available: available)
        default:
            throw ResolutionError.ambiguousService(name, projects: matches.map(\.0.config.name))
        }
    }
}

/// Persists the list of registered project roots at `~/.forge/projects.json`.
public struct ProjectRegistry: Sendable {
    private struct Contents: Codable {
        var projects: [String]
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge/projects.json")
    }

    public static func load(from url: URL = defaultURL) -> [URL] {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            return []
        }
        return contents.projects.map { URL(fileURLWithPath: $0) }
    }

    public static func save(_ roots: [URL], to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Contents(projects: roots.map(\.path))).write(to: url)
    }
}
