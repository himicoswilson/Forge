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

    // MARK: - Batched listeners

    @Test("listeningPids asks lsof for all ports in one LISTEN-only call")
    func listeningPidsCommand() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "p123\nf23\nn*:8080\n")
        }
        let checker = PortChecker(runner: runner)
        #expect(checker.listeningPids(onPorts: [8080, 9201]) == [8080: [123]])
        #expect(runner.commandLines == ["lsof -nP -iTCP:8080,9201 -sTCP:LISTEN -Fpn"])
    }

    @Test("listeningPids is empty when lsof finds nothing (exit 1)")
    func listeningPidsNoMatches() {
        let runner = MockCommandRunner { _ in CommandResult(exitCode: 1) }
        #expect(PortChecker(runner: runner).listeningPids(onPorts: [8080]).isEmpty)
    }

    @Test("listeningPids with no ports never spawns lsof")
    func listeningPidsEmptyInput() {
        let runner = MockCommandRunner()
        #expect(PortChecker(runner: runner).listeningPids(onPorts: []).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("parseListeners handles multiple processes and skips f-lines")
    func parseListenersMultiProcess() {
        let out = "p123\nf23\nn*:8080\np456\nf45\nn127.0.0.1:9201\n"
        #expect(PortChecker.parseListeners(out) == [8080: [123], 9201: [456]])
    }

    @Test("parseListeners dedupes IPv4+IPv6 dual-stack sockets per port")
    func parseListenersDualStack() {
        let out = "p123\nf23\nn*:8080\nf24\nn[::]:8080\n"
        #expect(PortChecker.parseListeners(out) == [8080: [123]])
    }

    @Test("parseListeners keeps first-seen pid order on a shared port")
    func parseListenersOrder() {
        let out = "p123\nn*:8080\np456\nn*:8080\n"
        #expect(PortChecker.parseListeners(out) == [8080: [123, 456]])
    }

    @Test("parseListeners maps one process listening on several ports")
    func parseListenersMultiPort() {
        let out = "p123\nn*:8080\nn[::1]:9201\n"
        #expect(PortChecker.parseListeners(out) == [8080: [123], 9201: [123]])
    }

    // MARK: - Batched process stats

    @Test("processStats asks ps for all pids in one call")
    func processStatsCommand() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 0, stdout: "  123 129024 01:23:45\n  456 2048 00:42\n")
        }
        let stats = PortChecker(runner: runner).processStats(of: [123, 456])
        #expect(stats == [
            123: PortChecker.ProcessStats(memoryKB: 129024, uptime: "01:23:45"),
            456: PortChecker.ProcessStats(memoryKB: 2048, uptime: "00:42"),
        ])
        #expect(runner.commandLines == ["ps -o pid=,rss=,etime= -p 123,456"])
    }

    @Test("processStats parses partial output despite exit 1 (one pid already gone)")
    func processStatsPartial() {
        let runner = MockCommandRunner { _ in
            CommandResult(exitCode: 1, stdout: "  123 129024 01:23:45\n")
        }
        let stats = PortChecker(runner: runner).processStats(of: [123, 999])
        #expect(stats == [123: PortChecker.ProcessStats(memoryKB: 129024, uptime: "01:23:45")])
    }

    @Test("processStats with no pids never spawns ps")
    func processStatsEmptyInput() {
        let runner = MockCommandRunner()
        #expect(PortChecker(runner: runner).processStats(of: []).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("parseStats skips malformed lines")
    func parseStatsMalformed() {
        let out = "garbage\n123 129024 01:23:45\nnot a pid 1 2\n"
        #expect(PortChecker.parseStats(out) == [123: PortChecker.ProcessStats(memoryKB: 129024, uptime: "01:23:45")])
    }
}
