import Foundation
import Testing
@testable import ForgeCore

@Suite("ForgeConfig")
struct ForgeConfigTests {

    /// Creates a throwaway project root, optionally with config + .java-version.
    private func makeRoot(name: String = "demo-project", config: String? = nil, javaVersion: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".forge"),
            withIntermediateDirectories: true
        )
        if let config {
            try Data(config.utf8).write(to: root.appendingPathComponent(ForgeConfig.relativePath))
        }
        if let javaVersion {
            try Data(javaVersion.utf8).write(to: root.appendingPathComponent(ForgeConfig.javaVersionFile))
        }
        return root
    }

    @Test("minimal config: only service name + port required")
    func minimalConfig() throws {
        let root = try makeRoot(config: """
        { "services": [ { "name": "gateway", "port": 8080 } ] }
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.name == "demo-project")
        #expect(config.prefix == "demo-project")
        #expect(config.jdk == nil)
        #expect(config.services == [ServiceConfig(name: "gateway", port: 8080)])
    }

    @Test("full config: explicit name, prefix and jdk are honoured")
    func fullConfig() throws {
        let root = try makeRoot(config: """
        {
          "name": "normal-cloud",
          "prefix": "wr",
          "jdk": "17",
          "services": [
            { "name": "gateway", "port": 8080 },
            { "name": "train",   "port": 9700, "module": "wr-train-svc" }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.name == "normal-cloud")
        #expect(config.prefix == "wr")
        #expect(config.jdk == "17")
        #expect(config.services.count == 2)
        #expect(config.services[1].module == "wr-train-svc")
    }

    @Test("legacy 'scripts' key is ignored, not an error")
    func legacyScriptsKeyIgnored() throws {
        let root = try makeRoot(config: """
        { "scripts": ".claude/scripts", "services": [ { "name": "auth", "port": 9201 } ] }
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.services.first?.name == "auth")
    }

    @Test("jdk falls back to .java-version in the project root")
    func jdkFromJavaVersionFile() throws {
        let root = try makeRoot(
            config: #"{ "services": [ { "name": "auth", "port": 9201 } ] }"#,
            javaVersion: "21\n"
        )
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.jdk == "21")
    }

    @Test("explicit jdk in config wins over .java-version")
    func explicitJdkWins() throws {
        let root = try makeRoot(
            config: #"{ "jdk": "17", "services": [ { "name": "auth", "port": 9201 } ] }"#,
            javaVersion: "21"
        )
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.jdk == "17")
    }

    @Test("no config file and nothing to discover throws noServices")
    func missingFileThrows() {
        let root = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: ConfigError.noServices(root.path)) {
            try ForgeConfig.load(projectRoot: root)
        }
    }

    @Test("malformed JSON throws invalid")
    func malformedJSONThrows() throws {
        let root = try makeRoot(config: "not json")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        #expect(throws: ConfigError.self) {
            try ForgeConfig.load(projectRoot: root)
        }
    }

    /// Drops a minimal one-module Maven tree into the root so discovery
    /// finds `<artifactId>` listening on `port`.
    private func addMavenModule(root: URL, artifactId: String, port: Int) throws {
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <artifactId>parent</artifactId>
          <modules>
            <module>\(artifactId)</module>
          </modules>
        </project>
        """.write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)

        let moduleDir = root.appendingPathComponent(artifactId)
        try FileManager.default.createDirectory(
            at: moduleDir.appendingPathComponent("src/main/resources"),
            withIntermediateDirectories: true
        )
        try """
        <project xmlns="http://maven.apache.org/POM/4.0.0"><artifactId>\(artifactId)</artifactId></project>
        """.write(to: moduleDir.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        try "server:\n  port: \(port)\n".write(
            to: moduleDir.appendingPathComponent("src/main/resources/application.yml"),
            atomically: true, encoding: .utf8
        )
    }

    @Test("no config file at all: services come from Maven discovery")
    func discoveryWithoutConfig() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try addMavenModule(root: root, artifactId: "demo-gateway", port: 8080)

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.name == "demo-project")
        #expect(config.prefix == "demo")
        #expect(config.services == [ServiceConfig(name: "gateway", port: 8080, module: "demo-gateway")])
    }

    @Test("config entry on the same port renames the discovered service instead of duplicating it")
    func configRenamesByPort() throws {
        let root = try makeRoot(config: """
        { "services": [ { "name": "wrong-gateway", "port": 8080 } ] }
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try addMavenModule(root: root, artifactId: "demo-gateway", port: 8080)

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.services == [ServiceConfig(name: "wrong-gateway", port: 8080, module: "demo-gateway")])
    }

    @Test("config overrides a discovered service's port and adds extra services")
    func configOverridesDiscovery() throws {
        let root = try makeRoot(config: """
        {
          "services": [
            { "name": "gateway", "port": 18080 },
            { "name": "job", "port": 9203, "module": "xxl-job-admin" }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try addMavenModule(root: root, artifactId: "demo-gateway", port: 8080)

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.services == [
            ServiceConfig(name: "gateway", port: 18080, module: "demo-gateway"),
            ServiceConfig(name: "job", port: 9203, module: "xxl-job-admin"),
        ])
    }

    @Test("module defaults to prefix-name and respects explicit override")
    func moduleResolution() {
        let config = ForgeConfig(
            name: "p", prefix: "wr",
            services: [
                ServiceConfig(name: "train", port: 9700),
                ServiceConfig(name: "file", port: 9300, module: "wr-file-storage"),
            ]
        )
        #expect(config.module(for: config.services[0]) == "wr-train")
        #expect(config.module(for: config.services[1]) == "wr-file-storage")
    }

    @Test("session name is prefix-name")
    func sessionName() {
        let config = ForgeConfig(name: "p", prefix: "wr",
                                 services: [ServiceConfig(name: "auth", port: 9201)])
        #expect(config.sessionName(for: config.services[0]) == "wr-auth")
    }
}
