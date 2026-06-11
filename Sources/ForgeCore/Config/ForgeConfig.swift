import Foundation

/// One managed service as declared in `.forge/config.json`.
public struct ServiceConfig: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let name: String
    public let port: Int
    /// Maven module for hot restart. Defaults to `<prefix>-<name>` when omitted.
    public let module: String?

    public var id: String { name }

    public init(name: String, port: Int, module: String? = nil) {
        self.name = name
        self.port = port
        self.module = module
    }
}

/// Per-project configuration, read from `<projectRoot>/.forge/config.json`.
public struct ForgeConfig: Sendable, Codable, Equatable {
    public let name: String
    public let prefix: String
    /// Directory holding `start-<service>.sh` scripts, relative to the project root.
    public let scripts: String
    public let services: [ServiceConfig]

    public init(name: String, prefix: String, scripts: String, services: [ServiceConfig]) {
        self.name = name
        self.prefix = prefix
        self.scripts = scripts
        self.services = services
    }

    public static let relativePath = ".forge/config.json"

    public static func load(projectRoot: URL) throws -> ForgeConfig {
        let url = projectRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ForgeConfig.self, from: data)
        } catch {
            throw ConfigError.invalid(url.path, underlying: "\(error)")
        }
    }

    public func service(named name: String) -> ServiceConfig? {
        services.first { $0.name == name }
    }

    /// Maven module used for `hotrestart_service`.
    public func module(for service: ServiceConfig) -> String {
        service.module ?? "\(prefix)-\(service.name)"
    }

    /// tmux session name owning a service: `<prefix>-<name>`.
    public func sessionName(for service: ServiceConfig) -> String {
        "\(prefix)-\(service.name)"
    }
}

public enum ConfigError: Error, Equatable {
    case notFound(String)
    case invalid(String, underlying: String)
}
