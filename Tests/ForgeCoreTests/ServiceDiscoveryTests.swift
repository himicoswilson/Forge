import Foundation
import Testing
@testable import ForgeCore

@Suite("ServiceDiscovery")
struct ServiceDiscoveryTests {

    /// Builds a throwaway Maven project tree. `modules` maps a module's
    /// relative path to the resource files it should contain
    /// (filename → contents); a nil resource map means aggregator-only.
    private func makeProject(
        rootModules: [String],
        modules: [String: (artifactId: String, resources: [String: String])]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pom(artifactId: "root", modules: rootModules)
            .write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)

        for (path, module) in modules {
            let dir = root.appendingPathComponent(path)
            let children = modules.keys
                .filter { $0.hasPrefix(path + "/") && !$0.dropFirst(path.count + 1).contains("/") }
                .map { String($0.dropFirst(path.count + 1)) }
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("src/main/resources"),
                withIntermediateDirectories: true
            )
            try pom(artifactId: module.artifactId, modules: children.sorted())
                .write(to: dir.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
            for (file, contents) in module.resources {
                try contents.write(
                    to: dir.appendingPathComponent("src/main/resources/\(file)"),
                    atomically: true, encoding: .utf8
                )
            }
        }
        return root
    }

    /// A pom.xml with the default Maven namespace, like real ones.
    private func pom(artifactId: String, modules: [String]) -> String {
        let moduleXML = modules.map { "    <module>\($0)</module>" }.joined(separator: "\n")
        let modulesBlock = modules.isEmpty ? "" : "  <modules>\n\(moduleXML)\n  </modules>\n"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0">
          <modelVersion>4.0.0</modelVersion>
          <groupId>com.example</groupId>
          <artifactId>\(artifactId)</artifactId>
          <version>1.0.0</version>
        \(modulesBlock)</project>
        """
    }

    @Test("discovers runnable modules with ports, skipping library modules")
    func discoversServices() throws {
        let root = try makeProject(
            rootModules: ["ruoyi-gateway", "ruoyi-auth", "ruoyi-common"],
            modules: [
                "ruoyi-gateway": ("ruoyi-gateway", ["bootstrap.yml": "server:\n  port: 8080\n"]),
                "ruoyi-auth": ("ruoyi-auth", ["bootstrap.yml": "server:\n  port: 9200\n"]),
                "ruoyi-common": ("ruoyi-common", [:]),  // library — no server.port
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        #expect(discovery.prefix == "ruoyi")
        #expect(discovery.services == [
            ServiceConfig(name: "gateway", port: 8080, module: "ruoyi-gateway"),
            ServiceConfig(name: "auth", port: 9200, module: "ruoyi-auth"),
        ])
    }

    @Test("recurses through nested aggregator modules")
    func nestedModules() throws {
        let root = try makeProject(
            rootModules: ["ruoyi-gateway", "ruoyi-modules"],
            modules: [
                "ruoyi-gateway": ("ruoyi-gateway", ["bootstrap.yml": "server:\n  port: 8080\n"]),
                "ruoyi-modules": ("ruoyi-modules", [:]),
                "ruoyi-modules/ruoyi-system": ("ruoyi-system", ["bootstrap.yml": "server:\n  port: 9201\n"]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        #expect(discovery.services == [
            ServiceConfig(name: "gateway", port: 8080, module: "ruoyi-gateway"),
            ServiceConfig(name: "system", port: 9201, module: "ruoyi-modules/ruoyi-system"),
        ])
    }

    @Test("reads server.port from application.properties too")
    func propertiesPort() throws {
        let root = try makeProject(
            rootModules: ["acme-billing"],
            modules: [
                "acme-billing": ("acme-billing", ["application.properties": "spring.application.name=billing\nserver.port=9300\n"]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        #expect(discovery.services == [ServiceConfig(name: "billing", port: 9300, module: "acme-billing")])
    }

    @Test("keeps full artifactIds when no common prefix exists")
    func noCommonPrefix() throws {
        let root = try makeProject(
            rootModules: ["gateway-svc", "billing"],
            modules: [
                "gateway-svc": ("gateway-svc", ["application.yml": "server:\n  port: 8080\n"]),
                "billing": ("billing", ["application.yml": "server:\n  port: 9300\n"]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        #expect(discovery.prefix == nil)
        #expect(discovery.services.map(\.name).sorted() == ["billing", "gateway-svc"])
    }

    @Test("discovers port from application-dev.yml when base yml has none")
    func profileSpecificPort() throws {
        let root = try makeProject(
            rootModules: ["chestnut-admin"],
            modules: [
                "chestnut-admin": ("chestnut-admin", [
                    "application.yml": "spring:\n  profiles:\n    active: dev\n",
                    "application-dev.yml": "server:\n  port: 9080\n",
                ]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        // Single module → prefix="chestnut", name stripped to "admin"
        #expect(discovery.services == [ServiceConfig(name: "admin", port: 9080, module: "chestnut-admin")])
    }

    @Test("project without poms discovers nothing")
    func noPoms() {
        let root = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(ServiceDiscovery.discover(projectRoot: root) == .empty)
    }

    @Test("supportsHotRestart is true when pom.xml contains spring-boot-devtools")
    func detectsDevTools() throws {
        let root = try makeProject(
            rootModules: ["ruoyi-auth", "ruoyi-gateway"],
            modules: [
                "ruoyi-auth": ("ruoyi-auth", ["bootstrap.yml": "server:\n  port: 9200\n"]),
                "ruoyi-gateway": ("ruoyi-gateway", ["bootstrap.yml": "server:\n  port: 8080\n"]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Inject spring-boot-devtools into the auth module pom only.
        let authPom = root.appendingPathComponent("ruoyi-auth/pom.xml")
        var pomText = (try? String(contentsOf: authPom, encoding: .utf8)) ?? ""
        pomText = pomText.replacingOccurrences(
            of: "</project>",
            with: """
              <dependencies>
                <dependency>
                  <groupId>org.springframework.boot</groupId>
                  <artifactId>spring-boot-devtools</artifactId>
                  <optional>true</optional>
                </dependency>
              </dependencies>
            </project>
            """
        )
        try pomText.write(to: authPom, atomically: true, encoding: .utf8)

        let discovery = ServiceDiscovery.discover(projectRoot: root)
        let auth = discovery.services.first { $0.name == "auth" }
        let gateway = discovery.services.first { $0.name == "gateway" }
        #expect(auth?.supportsHotRestart == true)
        #expect(gateway?.supportsHotRestart == false)
    }

    // MARK: - Port parsing

    @Test("YAML scan finds port only inside the server block")
    func yamlScan() {
        #expect(ServiceDiscovery.serverPort(inYAML: """
        spring:
          application:
            name: gateway
        server:
          port: 8080
          servlet:
            context-path: /
        """) == 8080)

        // A port under a different top-level key must not match.
        #expect(ServiceDiscovery.serverPort(inYAML: """
        management:
          port: 9999
        """) == nil)
    }

    @Test("port values tolerate comments and ${PLACEHOLDER:default}")
    func portValues() {
        #expect(ServiceDiscovery.portValue(" 9200 ") == 9200)
        #expect(ServiceDiscovery.portValue(" 9200 # overridden in prod") == 9200)
        #expect(ServiceDiscovery.portValue(" ${SERVER_PORT:9200}") == 9200)
        #expect(ServiceDiscovery.portValue(" ${SERVER_PORT}") == nil)
        #expect(ServiceDiscovery.portValue("not-a-port") == nil)
    }
}
