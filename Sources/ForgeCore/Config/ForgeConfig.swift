import Foundation

/// One managed service as declared in `.forge/config.json`.
public struct ServiceConfig: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let name: String
    public let port: Int
    /// Maven module the service lives in. Defaults to `<prefix>-<name>` when omitted.
    public let module: String?

    public var id: String { name }

    public init(name: String, port: Int, module: String? = nil) {
        self.name = name
        self.port = port
        self.module = module
    }
}

/// Per-project configuration, read from `<projectRoot>/.forge/config.json`.
///
/// Only `services` is required — the minimal config is:
/// ```json
/// { "services": [ { "name": "gateway", "port": 8080 } ] }
/// ```
/// Defaults: `name` ← project folder name, `prefix` ← `name`,
/// `jdk` ← contents of `.java-version` in the project root (if present).
public struct ForgeConfig: Sendable, Equatable {
    public let name: String
    public let prefix: String
    /// JDK version services run with (e.g. "17"), resolved to a JAVA_HOME
    /// via `/usr/libexec/java_home -v`. `nil` = whatever `java` is on PATH.
    public let jdk: String?
    public let services: [ServiceConfig]

    public init(name: String, prefix: String, jdk: String? = nil, services: [ServiceConfig]) {
        self.name = name
        self.prefix = prefix
        self.jdk = jdk
        self.services = services
    }

    public static let relativePath = ".forge/config.json"
    public static let javaVersionFile = ".java-version"

    /// All fields except `services` are optional in the JSON.
    private struct Raw: Decodable {
        let name: String?
        let prefix: String?
        let jdk: String?
        let services: [ServiceConfig]
    }

    public static func load(projectRoot: URL) throws -> ForgeConfig {
        let url = projectRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(url.path)
        }
        let data = try Data(contentsOf: url)
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw ConfigError.invalid(url.path, underlying: "\(error)")
        }

        let name = raw.name ?? projectRoot.lastPathComponent
        return ForgeConfig(
            name: name,
            prefix: raw.prefix ?? name,
            jdk: raw.jdk ?? javaVersion(projectRoot: projectRoot),
            services: raw.services
        )
    }

    /// JDK version from `.java-version` in the project root (jenv/asdf convention).
    private static func javaVersion(projectRoot: URL) -> String? {
        let url = projectRoot.appendingPathComponent(javaVersionFile)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    public func service(named name: String) -> ServiceConfig? {
        services.first { $0.name == name }
    }

    /// Maven module a service is built from.
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
