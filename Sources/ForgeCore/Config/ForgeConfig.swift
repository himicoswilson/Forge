import Foundation

/// One managed service as declared in `.forge/config.json`.
public struct ServiceConfig: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let name: String
    public let port: Int
    /// Maven module the service lives in. Defaults to `<prefix>-<name>` when omitted.
    public let module: String?
    /// True when the service's pom.xml declares spring-boot-devtools (detected at discovery
    /// time). Hot Restart is unavailable without it. Can be forced true in .forge/config.json.
    public let supportsHotRestart: Bool

    public var id: String { name }

    public init(name: String, port: Int, module: String? = nil, supportsHotRestart: Bool = false) {
        self.name = name
        self.port = port
        self.module = module
        self.supportsHotRestart = supportsHotRestart
    }

    private enum CodingKeys: String, CodingKey {
        case name, port, module, supportsHotRestart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decode(Int.self, forKey: .port)
        module = try c.decodeIfPresent(String.self, forKey: .module)
        supportsHotRestart = try c.decodeIfPresent(Bool.self, forKey: .supportsHotRestart) ?? false
    }
}

/// Per-project configuration: services auto-discovered from the Maven
/// module tree (see `ServiceDiscovery`), optionally overridden by
/// `<projectRoot>/.forge/config.json`.
///
/// The config file is not required at all when discovery finds the
/// services. When present, every field is optional: entries in `services`
/// override a discovered service of the same name (or add one discovery
/// can't see), and `name`/`prefix`/`jdk` replace the derived defaults
/// (`name` ← project folder name, `prefix` ← shared artifactId prefix,
/// `jdk` ← `.java-version` contents).
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

    /// Every field is optional in the JSON.
    private struct Raw: Decodable {
        let name: String?
        let prefix: String?
        let jdk: String?
        let services: [ServiceConfig]?
    }

    public static func load(projectRoot: URL) throws -> ForgeConfig {
        let url = projectRoot.appendingPathComponent(relativePath)
        var raw: Raw?
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do {
                raw = try JSONDecoder().decode(Raw.self, from: data)
            } catch {
                throw ConfigError.invalid(url.path, underlying: "\(error)")
            }
        }

        let discovery = ServiceDiscovery.discover(projectRoot: projectRoot)
        var services = discovery.services
        for override in raw?.services ?? [] {
            // Same name or same port = the same service (a port identifies a
            // service); the config entry wins, keeping the discovered module
            // unless it overrides that too.
            if let index = services.firstIndex(where: { $0.name == override.name || $0.port == override.port }) {
                services[index] = ServiceConfig(
                    name: override.name,
                    port: override.port,
                    module: override.module ?? services[index].module,
                    // Config can force true; otherwise keep what discovery found in pom.xml.
                    supportsHotRestart: override.supportsHotRestart || services[index].supportsHotRestart
                )
            } else {
                services.append(override)
            }
        }
        guard !services.isEmpty else {
            throw ConfigError.noServices(projectRoot.path)
        }

        let name = raw?.name ?? projectRoot.lastPathComponent
        return ForgeConfig(
            name: name,
            prefix: raw?.prefix ?? discovery.prefix ?? name,
            jdk: raw?.jdk ?? javaVersion(projectRoot: projectRoot),
            services: services
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
    /// Neither Maven discovery nor `.forge/config.json` produced a single service.
    case noServices(String)
    case invalid(String, underlying: String)
}
