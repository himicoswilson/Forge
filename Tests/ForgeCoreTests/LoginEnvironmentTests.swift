import Foundation
import Testing
@testable import ForgeCore

@Suite("LoginEnvironment")
struct LoginEnvironmentTests {

    @Test("parses PATH out of `env` output")
    func parsePath() {
        let output = """
        HOME=/Users/dev
        PATH=/opt/homebrew/bin:/usr/bin:/bin
        SHELL=/opt/homebrew/bin/fish
        """
        #expect(LoginEnvironment.parsePath(fromEnvOutput: output) == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test("missing or empty PATH yields nil")
    func parseMissingPath() {
        #expect(LoginEnvironment.parsePath(fromEnvOutput: "HOME=/Users/dev\n") == nil)
        #expect(LoginEnvironment.parsePath(fromEnvOutput: "PATH=\nHOME=/x\n") == nil)
    }

    @Test("merge appends only the extras that are not already present")
    func mergeAppendsMissingExtras() {
        let merged = LoginEnvironment.mergedPath(
            resolved: "/opt/homebrew/bin:/usr/bin",
            current: nil,
            extras: ["/opt/homebrew/bin", "/Users/dev/.jenv/shims"]
        )
        #expect(merged == "/opt/homebrew/bin:/usr/bin:/Users/dev/.jenv/shims")
    }

    @Test("falls back to the current PATH, then to the system default")
    func mergeFallbacks() {
        #expect(LoginEnvironment.mergedPath(resolved: nil, current: "/usr/bin", extras: []) == "/usr/bin")
        #expect(LoginEnvironment.mergedPath(resolved: nil, current: nil, extras: []) == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("default extras cover Homebrew, /usr/local and jenv shims")
    func defaultExtras() {
        #expect(LoginEnvironment.defaultExtras(home: "/Users/dev") == [
            "/opt/homebrew/bin", "/usr/local/bin", "/Users/dev/.jenv/shims",
        ])
    }
}
