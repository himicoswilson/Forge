import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("Workspace")
struct WorkspaceTests {

    private func manager(_ project: String, prefix: String, services: [String: Int]) -> ServiceManager {
        ServiceManager(
            config: ForgeConfig(
                name: project, prefix: prefix,
                services: services.sorted { $0.key < $1.key }.map { ServiceConfig(name: $0.key, port: $0.value) }
            ),
            projectRoot: URL(fileURLWithPath: "/projects/\(project)"),
            runner: MockCommandRunner.simulating()
        )
    }

    private func makeWorkspace() async -> Workspace {
        let workspace = Workspace(runner: MockCommandRunner.simulating())
        await workspace.register(manager("cloud-a", prefix: "wr", services: ["gateway": 8080, "auth": 9201]))
        await workspace.register(manager("cloud-b", prefix: "nb", services: ["gateway": 18080, "billing": 19000]))
        return workspace
    }

    @Test("unique service name resolves without naming the project")
    func uniqueResolution() async throws {
        let workspace = await makeWorkspace()
        let (manager, service) = try await workspace.resolve(service: "billing")
        #expect(manager.config.name == "cloud-b")
        #expect(service.port == 19000)
    }

    @Test("duplicated service name requires the project argument")
    func ambiguousResolution() async throws {
        let workspace = await makeWorkspace()
        await #expect(throws: Workspace.ResolutionError.ambiguousService("gateway", projects: ["cloud-a", "cloud-b"])) {
            try await workspace.resolve(service: "gateway")
        }
        let (manager, _) = try await workspace.resolve(service: "gateway", project: "cloud-a")
        #expect(manager.config.name == "cloud-a")
    }

    @Test("unknown project and unknown service produce dedicated errors")
    func unknownErrors() async throws {
        let workspace = await makeWorkspace()
        await #expect(throws: Workspace.ResolutionError.unknownProject("nope", known: ["cloud-a", "cloud-b"])) {
            try await workspace.resolve(service: "gateway", project: "nope")
        }
        await #expect(throws: Workspace.ResolutionError.self) {
            try await workspace.resolve(service: "nope")
        }
    }

    @Test("empty workspace reports noProjects")
    func emptyWorkspace() async throws {
        let workspace = Workspace(runner: MockCommandRunner.simulating())
        await #expect(throws: Workspace.ResolutionError.noProjects) {
            try await workspace.resolve(service: "anything")
        }
    }

    @Test("addProject loads config from disk; re-adding the same root replaces it")
    func addProjectFromDisk() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)")
        let root = base.appendingPathComponent("my-cloud")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".forge"), withIntermediateDirectories: true)
        try Data(#"{ "services": [ { "name": "auth", "port": 9201 } ] }"#.utf8)
            .write(to: root.appendingPathComponent(ForgeConfig.relativePath))

        let workspace = Workspace(runner: MockCommandRunner.simulating())
        try await workspace.addProject(root: root)
        try await workspace.addProject(root: root)

        let projects = await workspace.projects
        #expect(projects.count == 1)
        #expect(projects.first?.config.name == "my-cloud")
        #expect(projects.first?.config.prefix == "my-cloud")
    }

    @Test("project registry round-trips roots through JSON on disk")
    func registryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)/registry/projects.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        let roots = [URL(fileURLWithPath: "/projects/cloud-a"), URL(fileURLWithPath: "/projects/cloud-b")]
        try ProjectRegistry.save(roots, to: url)
        #expect(ProjectRegistry.load(from: url) == roots)
    }

    @Test("loading a missing registry yields an empty list")
    func missingRegistry() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/projects.json")
        #expect(ProjectRegistry.load(from: url).isEmpty)
    }
}
