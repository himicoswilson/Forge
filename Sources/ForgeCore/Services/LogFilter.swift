import Foundation

/// Pure log-text querying: regex matches with surrounding context
/// (grep -C style), time-window filtering on embedded line timestamps,
/// and tail limiting. No I/O — fully unit-testable.
public enum LogFilter {

    public enum QueryError: Error, Equatable {
        case invalidPattern(String)
        case invalidDuration(String)
    }

    /// Parses "30s" / "5m" / "2h" into seconds; a bare number means seconds.
    public static func parseDuration(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = try? /(\d+)\s*([smh]?)/.wholeMatch(in: trimmed),
              let value = TimeInterval(match.1) else {
            throw QueryError.invalidDuration(text)
        }
        switch match.2 {
        case "m": return value * 60
        case "h": return value * 3600
        default: return value
        }
    }

    /// Applies, in order: `since` (drop entries older than now − since),
    /// `pattern` (keep matching lines ± `context` lines, blocks separated
    /// by `--` when context > 0), then `limit` (keep the last N lines,
    /// noting the truncation). Untimestamped lines inherit the previous
    /// timestamped line's time, so stack traces stay with their entry;
    /// when no line carries a recognizable timestamp, `since` is skipped
    /// with a note instead of silently returning nothing.
    public static func apply(
        to text: String,
        pattern: String? = nil,
        context: Int = 0,
        since: TimeInterval? = nil,
        limit: Int = 100,
        now: Date = Date()
    ) throws -> String {
        // pipe-pane mirrors raw pty output, so real log files end lines with
        // CRLF — and Swift treats "\r\n" as ONE Character (grapheme cluster),
        // which `split(separator: "\n")` does not match. Split on
        // `isNewline` instead: it covers "\r\n", "\n", and the lone "\r" of
        // progress-bar rewrites, and keeps "\r" out of the output.
        var lines = stripANSI(text)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }

        var notes: [String] = []

        if let since {
            let cutoff = now.addingTimeInterval(-since)
            var lastTimestamp: Date?
            var kept: [String] = []
            for line in lines {
                if let ts = timestamp(of: line, now: now) { lastTimestamp = ts }
                // Lines before the first timestamp (e.g. Maven build output)
                // are older than anything stamped — drop them.
                if let lastTimestamp, lastTimestamp >= cutoff { kept.append(line) }
            }
            if lastTimestamp != nil {
                lines = kept
            } else {
                notes.append("(no timestamps recognized in the log — 'since' not applied)")
            }
        }

        if let pattern {
            let regex = try compile(pattern)
            let context = max(0, context)
            var blocks: [ClosedRange<Int>] = []
            for i in lines.indices where lines[i].contains(regex) {
                let block = max(0, i - context)...min(lines.count - 1, i + context)
                if let last = blocks.last, block.lowerBound <= last.upperBound + 1 {
                    blocks[blocks.count - 1] = last.lowerBound...block.upperBound
                } else {
                    blocks.append(block)
                }
            }
            var out: [String] = []
            for block in blocks {
                if !out.isEmpty && context > 0 { out.append("--") }
                out.append(contentsOf: lines[block])
            }
            lines = out
        }

        if limit > 0, lines.count > limit {
            notes.append("… (showing last \(limit) of \(lines.count) lines)")
            lines = Array(lines.suffix(limit))
        }
        return (notes + lines).joined(separator: "\n")
    }

    /// Compiles a user-supplied pattern, mapping failure to `invalidPattern`.
    /// Public so callers can validate arguments before doing I/O.
    public static func compile(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        guard let regex = try? Regex(pattern) else {
            throw QueryError.invalidPattern(pattern)
        }
        return regex
    }

    /// Timestamp at the start of a log line: Spring Boot's default
    /// "2026-06-12 15:04:05" (or T-separated) and time-only logback
    /// patterns like "15:04:05.123" (assumed today; a stamp later than
    /// `now` means it crossed midnight, so it counts as yesterday).
    static func timestamp(of line: String, now: Date, calendar: Calendar = .current) -> Date? {
        if let m = try? /(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.prefixMatch(in: line) {
            var c = DateComponents()
            c.year = Int(m.1); c.month = Int(m.2); c.day = Int(m.3)
            c.hour = Int(m.4); c.minute = Int(m.5); c.second = Int(m.6)
            return calendar.date(from: c)
        }
        if let m = try? /(\d{2}):(\d{2}):(\d{2})/.prefixMatch(in: line) {
            var c = calendar.dateComponents([.year, .month, .day], from: now)
            c.hour = Int(m.1); c.minute = Int(m.2); c.second = Int(m.3)
            guard let date = calendar.date(from: c) else { return nil }
            return date > now.addingTimeInterval(60)
                ? calendar.date(byAdding: .day, value: -1, to: date)
                : date
        }
        return nil
    }

    /// pipe-pane mirrors raw terminal output, colour codes included — drop
    /// CSI escape sequences so regexes and timestamp detection see clean text.
    static func stripANSI(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }
}
