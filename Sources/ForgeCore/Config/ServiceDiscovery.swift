import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Statically discovers runnable Spring Boot services in a Maven
/// multi-module project: follows `<modules>` from the root `pom.xml` and
/// treats every leaf module that declares a local `server.port` in its
/// resources as a service. Modules that keep their port in a config centre
/// (Nacos, Spring Cloud Config) are invisible here — declare those in
/// `.forge/config.json`.
public enum ServiceDiscovery {
    public struct Discovery: Sendable, Equatable {
        /// First artifactId segment shared by every discovered service
        /// (`ruoyi` for `ruoyi-auth` + `ruoyi-gateway`); nil when they
        /// don't agree.
        public let prefix: String?
        /// One entry per runnable module, in pom order. `module` is the
        /// path relative to the project root (what `mvn -pl` receives).
        public let services: [ServiceConfig]

        public static let empty = Discovery(prefix: nil, services: [])
    }

    public static func discover(projectRoot: URL) -> Discovery {
        var found: [(artifactId: String, path: String, port: Int)] = []
        collect(moduleDir: projectRoot, relativePath: "", into: &found)
        guard !found.isEmpty else { return .empty }

        let prefix = sharedPrefix(of: found.map(\.artifactId))
        let services = found.map { module in
            let name: String
            if let prefix, module.artifactId.hasPrefix(prefix + "-") {
                name = String(module.artifactId.dropFirst(prefix.count + 1))
            } else {
                name = module.artifactId
            }
            return ServiceConfig(name: name, port: module.port, module: module.path)
        }
        return Discovery(prefix: prefix, services: services)
    }

    // MARK: - Maven module tree

    /// Maven poms carry a default namespace, which XPath cannot address with
    /// plain element names — match on local-name() instead.
    private static let modulesXPath =
        "/*[local-name()='project']/*[local-name()='modules']/*[local-name()='module']"
    private static let artifactIdXPath =
        "/*[local-name()='project']/*[local-name()='artifactId']"

    private static func collect(
        moduleDir: URL,
        relativePath: String,
        into found: inout [(artifactId: String, path: String, port: Int)]
    ) {
        let pomURL = moduleDir.appendingPathComponent("pom.xml")
        guard let data = try? Data(contentsOf: pomURL),
              let pom = try? XMLDocument(data: data) else { return }

        let children = (try? pom.nodes(forXPath: modulesXPath))?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !children.isEmpty {
            // Aggregator — not a service itself.
            for child in children {
                collect(
                    moduleDir: moduleDir.appendingPathComponent(child),
                    relativePath: relativePath.isEmpty ? child : "\(relativePath)/\(child)",
                    into: &found
                )
            }
            return
        }

        guard !relativePath.isEmpty, let port = serverPort(inModule: moduleDir) else { return }
        let artifactId = (try? pom.nodes(forXPath: artifactIdXPath))?.first?.stringValue
            ?? moduleDir.lastPathComponent
        found.append((artifactId: artifactId, path: relativePath, port: port))
    }

    /// `prefix` is only meaningful when every artifactId starts with the
    /// same `<segment>-`.
    private static func sharedPrefix(of artifactIds: [String]) -> String? {
        let segments = Set(artifactIds.map { String($0.split(separator: "-").first ?? "") })
        guard segments.count == 1, let prefix = segments.first, !prefix.isEmpty,
              artifactIds.allSatisfy({ $0.hasPrefix(prefix + "-") }) else {
            return nil
        }
        return prefix
    }

    // MARK: - server.port extraction

    private static let resourceCandidates = [
        "bootstrap.yml", "bootstrap.yaml",
        "application.yml", "application.yaml",
        "bootstrap.properties", "application.properties",
        // Profile-specific fallbacks — many projects keep server.port only
        // in the active profile (commonly "dev" for local runs).
        "bootstrap-dev.yml", "bootstrap-dev.yaml",
        "application-dev.yml", "application-dev.yaml",
        "bootstrap-local.yml", "bootstrap-local.yaml",
        "application-local.yml", "application-local.yaml",
        "bootstrap-dev.properties", "application-dev.properties",
        "bootstrap-local.properties", "application-local.properties",
    ]

    static func serverPort(inModule moduleDir: URL) -> Int? {
        let resources = moduleDir.appendingPathComponent("src/main/resources")
        for candidate in resourceCandidates {
            let url = resources.appendingPathComponent(candidate)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let port = candidate.hasSuffix(".properties")
                ? serverPort(inProperties: text)
                : serverPort(inYAML: text)
            if let port { return port }
        }
        return nil
    }

    /// Minimal indentation-aware scan for `port:` inside a top-level
    /// `server:` block — not a YAML parser, but all Spring Boot port
    /// declarations in the wild look exactly like this.
    static func serverPort(inYAML text: String) -> Int? {
        var inServer = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inServer = trimmed == "server:"
                continue
            }
            if inServer, trimmed.hasPrefix("port:") {
                return portValue(String(trimmed.dropFirst("port:".count)))
            }
        }
        return nil
    }

    static func serverPort(inProperties text: String) -> Int? {
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "server.port" {
                return portValue(String(trimmed[trimmed.index(after: equals)...]))
            }
        }
        return nil
    }

    /// `9200`, `9200 # comment`, or `${SERVER_PORT:9200}` (the placeholder's
    /// default) → 9200.
    static func portValue(_ raw: String) -> Int? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("${"), value.hasSuffix("}") {
            let inner = value.dropFirst(2).dropLast()
            guard let colon = inner.lastIndex(of: ":") else { return nil }
            value = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return Int(value)
    }
}
