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

    @Test("missing config file throws notFound")
    func missingFileThrows() {
        let root = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: ConfigError.notFound(root.appendingPathComponent(ForgeConfig.relativePath).path)) {
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
