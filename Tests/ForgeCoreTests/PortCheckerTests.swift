import Foundation
import ForgeTestSupport
import Testing
@testable import ForgeCore

@Suite("PortChecker")
struct PortCheckerTests {

    @Test("parses PIDs from lsof output")
    func parsesPids() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "123\n456\n")
        }
        let checker = PortChecker(runner: runner)
        #expect(checker.pids(onPort: 8080) == [123, 456])
        #expect(runner.commandLines == ["lsof -ti:8080"])
    }

    @Test("free port (lsof exit 1) yields no PIDs")
    func freePort() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 1) }
        let checker = PortChecker(runner: runner)
        #expect(checker.pids(onPort: 9700).isEmpty)
    }

    @Test("processInfo parses rss and etime from ps")
    func processInfo() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: " 129024  01:23:45\n")
        }
        let checker = PortChecker(runner: runner)
        let info = checker.processInfo(pid: 123)
        #expect(info?.memoryKB == 129024)
        #expect(info?.uptime == "01:23:45")
        #expect(runner.commandLines == ["ps -o rss=,etime= -p 123"])
    }

    @Test("processInfo is nil for a dead PID")
    func deadPid() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 1) }
        let checker = PortChecker(runner: runner)
        #expect(checker.processInfo(pid: 999) == nil)
    }
}
