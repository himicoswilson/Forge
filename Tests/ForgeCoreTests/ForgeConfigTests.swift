import Foundation
import Testing
@testable import ForgeCore

@Suite("ForgeConfig")
struct ForgeConfigTests {

    static let specJSON = """
    {
      "name": "normal-cloud",
      "prefix": "wr",
      "scripts": ".claude/skills/cloud-run/scripts",
      "services": [
        { "name": "gateway", "port": 8080 },
        { "name": "auth",    "port": 9201 },
        { "name": "train",   "port": 9700 }
      ]
    }
    """

    @Test("decodes the SPEC sample config")
    func decodesSpecSample() throws {
        let config = try JSONDecoder().decode(ForgeConfig.self, from: Data(Self.specJSON.utf8))
        #expect(config.name == "normal-cloud")
        #expect(config.prefix == "wr")
        #expect(config.scripts == ".claude/skills/cloud-run/scripts")
        #expect(config.services.count == 3)
        #expect(config.services[0] == ServiceConfig(name: "gateway", port: 8080))
    }

    @Test("loads from <root>/.forge/config.json")
    func loadsFromProjectRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent(".forge")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(Self.specJSON.utf8).write(to: configDir.appendingPathComponent("config.json"))

        let config = try ForgeConfig.load(projectRoot: root)
        #expect(config.name == "normal-cloud")
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent(".forge")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: configDir.appendingPathComponent("config.json"))

        #expect(throws: ConfigError.self) {
            try ForgeConfig.load(projectRoot: root)
        }
    }

    @Test("module defaults to prefix-name and respects explicit override")
    func moduleResolution() {
        let config = ForgeConfig(
            name: "p", prefix: "wr", scripts: "scripts",
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
        let config = ForgeConfig(name: "p", prefix: "wr", scripts: "s",
                                 services: [ServiceConfig(name: "auth", port: 9201)])
        #expect(config.sessionName(for: config.services[0]) == "wr-auth")
    }
}
