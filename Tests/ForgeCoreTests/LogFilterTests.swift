import Foundation
import Testing
@testable import ForgeCore

@Suite("LogFilter")
struct LogFilterTests {

    // MARK: - Tail / limit

    @Test("plain tail keeps the last N lines and notes the truncation")
    func tailLimit() throws {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let output = try LogFilter.apply(to: text, limit: 3)
        #expect(output == "… (showing last 3 of 10 lines)\nline 8\nline 9\nline 10")
    }

    @Test("short logs come back whole, without a truncation note")
    func noTruncation() throws {
        #expect(try LogFilter.apply(to: "a\nb\n", limit: 100) == "a\nb")
    }

    // MARK: - Pattern

    @Test("pattern keeps only matching lines (no separators without context)")
    func patternOnly() throws {
        let output = try LogFilter.apply(to: "ok\nERROR one\nok\nERROR two\n", pattern: "ERROR")
        #expect(output == "ERROR one\nERROR two")
    }

    @Test("context expands matches grep -C style, merging overlaps, '--' between blocks")
    func patternWithContext() throws {
        let text = "a\nb\nERROR x\nc\nd\ne\nf\nERROR y\ng\n"
        let output = try LogFilter.apply(to: text, pattern: "ERROR", context: 1)
        #expect(output == "b\nERROR x\nc\n--\nf\nERROR y\ng")
    }

    @Test("adjacent context blocks merge instead of duplicating lines")
    func contextMerging() throws {
        let output = try LogFilter.apply(to: "a\nERROR x\nb\nERROR y\nc\n", pattern: "ERROR", context: 1)
        #expect(output == "a\nERROR x\nb\nERROR y\nc")
    }

    @Test("invalid regex throws invalidPattern")
    func invalidPattern() {
        #expect(throws: LogFilter.QueryError.invalidPattern("[")) {
            try LogFilter.apply(to: "x", pattern: "[")
        }
    }

    @Test("CRLF line endings (real pipe-pane files) split correctly — '\\r\\n' is one Swift Character")
    func crlfSplitting() throws {
        // Regression: split(separator: "\n") silently matched nothing here,
        // because Swift folds "\r\n" into a single grapheme cluster — the
        // whole file became one giant "line" and every filter degenerated.
        let text = "ok\r\nERROR boom\r\nok\r\n"
        #expect(try LogFilter.apply(to: text, pattern: "ERROR") == "ERROR boom")
        #expect(try LogFilter.apply(to: text, limit: 2) == "… (showing last 2 of 3 lines)\nERROR boom\nok")
    }

    @Test("lone \\r progress rewrites split into frames instead of merging lines")
    func carriageReturnFrames() throws {
        let text = "Progress (1): 10%\rProgress (2): 99%\r\nDone\r\n"
        #expect(try LogFilter.apply(to: text, pattern: "Done") == "Done")
    }

    @Test("ANSI colour codes are stripped before matching")
    func ansiStripped() throws {
        let output = try LogFilter.apply(to: "\u{1B}[31mERROR\u{1B}[0m boom\nok\n", pattern: "^ERROR")
        #expect(output == "ERROR boom")
    }

    // MARK: - since

    private let calendar = Calendar.current

    private func date(_ h: Int, _ m: Int, _ s: Int, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: h, minute: m, second: s))!
    }

    @Test("since keeps only entries newer than the cutoff")
    func sinceFilters() throws {
        let text = """
            2026-06-12 15:00:00 old entry
            2026-06-12 15:09:30 recent entry
            """
        let output = try LogFilter.apply(to: text, since: 300, now: date(15, 10, 0))
        #expect(output == "2026-06-12 15:09:30 recent entry")
    }

    @Test("untimestamped lines inherit the previous entry's time (stack traces stay attached)")
    func sinceKeepsContinuationLines() throws {
        let text = """
            2026-06-12 15:00:00 old entry
            \tat old.Frame(Old.java:1)
            2026-06-12 15:09:30 ERROR recent
            \tat com.foo.Bar(Bar.java:10)
            """
        let output = try LogFilter.apply(to: text, since: 300, now: date(15, 10, 0))
        #expect(output == "2026-06-12 15:09:30 ERROR recent\n\tat com.foo.Bar(Bar.java:10)")
    }

    @Test("time-only timestamps (logback HH:mm:ss.SSS) are understood")
    func sinceTimeOnly() throws {
        let text = "15:00:00.123 old\n15:09:30.456 recent\n"
        let output = try LogFilter.apply(to: text, since: 300, now: date(15, 10, 0))
        #expect(output == "15:09:30.456 recent")
    }

    @Test("a log without recognizable timestamps is returned whole, with a note")
    func sinceWithoutTimestamps() throws {
        let output = try LogFilter.apply(to: "mvn downloading...\nBUILD SUCCESS\n", since: 60)
        #expect(output.hasPrefix("(no timestamps recognized"))
        #expect(output.contains("BUILD SUCCESS"))
    }

    @Test("a time-only stamp later than 'now' counts as yesterday (midnight crossing)")
    func sinceMidnightCrossing() {
        let now = date(0, 5, 0) // 00:05
        let ts = LogFilter.timestamp(of: "23:58:00.000 late entry", now: now)
        #expect(ts == date(23, 58, 0, day: 11))
    }

    // MARK: - parseDuration

    @Test("durations: 30s, 5m, 2h, bare seconds")
    func durations() throws {
        #expect(try LogFilter.parseDuration("30s") == 30)
        #expect(try LogFilter.parseDuration("5m") == 300)
        #expect(try LogFilter.parseDuration("2h") == 7200)
        #expect(try LogFilter.parseDuration("90") == 90)
    }

    @Test("invalid duration throws")
    func invalidDuration() {
        #expect(throws: LogFilter.QueryError.invalidDuration("yesterday")) {
            try LogFilter.parseDuration("yesterday")
        }
    }
}
