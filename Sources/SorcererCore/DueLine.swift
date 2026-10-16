import Foundation

/// Reads and writes the deadline line at the top of a reminder's notes.
///
/// Canonical form (what TaskSorcerer writes): `Due: MM-DD-YY` or `Due: MM-DD-YY h:mm AM`.
/// Reading is lenient: the year and time are optional, `/` or `.` work as separators,
/// and times like `5pm`, `5:30 p.m.` or `17:00` are accepted.
public enum DueLine {
    public struct Parsed: Equatable {
        public var date: TaskDate
        /// False when the year was left out and had to be inferred.
        public var hadYear: Bool
    }

    /// How far in the past a year-less date may fall before it's assumed to mean next year.
    static let yearlessLookbackDays = 60

    private static let pattern = try! NSRegularExpression(
        pattern: #"""
        ^\s*(?:📅\s*)?due\s*[:\-–]?\s*
        (\d{1,2})\s*[-/.]\s*(\d{1,2})
        (?:\s*[-/.]\s*(\d{4}|\d{2}))?
        (?:\s*(?:@|at)?\s*(\d{1,2})(?::(\d{2}))?\s*(?:([ap])\.?\s*(?:m\.?)?)?)?
        \s*$
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    /// Parses the first line of `notes`, if it is a due line.
    public static func parse(notes: String, today: Date = Date(), calendar: Calendar = .current) -> Parsed? {
        guard let line = firstLine(of: notes) else { return nil }
        return parse(line: line, today: today, calendar: calendar)
    }

    public static func parse(line: String, today: Date = Date(), calendar: Calendar = .current) -> Parsed? {
        let ns = line as NSString
        guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let month = group(1).flatMap(Int.init), let day = group(2).flatMap(Int.init) else { return nil }

        var hour: Int?
        var minute: Int?
        if let h = group(4).flatMap(Int.init) {
            let mins = group(5).flatMap(Int.init) ?? 0
            guard (0...59).contains(mins) else { return nil }
            if let meridiem = group(6)?.lowercased() {
                guard (1...12).contains(h) else { return nil }
                hour = meridiem == "p" ? (h % 12) + 12 : h % 12
            } else {
                guard (0...23).contains(h) else { return nil }
                hour = h
            }
            minute = mins
        }

        let hadYear: Bool
        var year: Int
        if let y = group(3).flatMap(Int.init) {
            hadYear = true
            year = y < 100 ? 2000 + y : y
        } else {
            hadYear = false
            year = calendar.component(.year, from: today)
            if let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
               let cutoff = calendar.date(byAdding: .day, value: -yearlessLookbackDays, to: calendar.startOfDay(for: today)),
               candidate < cutoff {
                year += 1
            }
        }

        let comps = DateComponents(calendar: calendar, year: year, month: month, day: day)
        guard (1...12).contains(month), comps.isValidDate else { return nil }
        return Parsed(date: TaskDate(year: year, month: month, day: day, hour: hour, minute: minute), hadYear: hadYear)
    }

    /// `Due: 10-20-26` or `Due: 10-20-26 5:30 PM`.
    public static func format(_ date: TaskDate) -> String {
        var s = String(format: "Due: %02d-%02d-%02d", date.month, date.day, date.year % 100)
        if let hour = date.hour {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            s += String(format: " %d:%02d %@", h12, date.minute ?? 0, hour < 12 ? "AM" : "PM")
        }
        return s
    }

    /// Returns `notes` with its due line set to `date`: replaced if present, added as the first
    /// line if not, removed when `date` is nil. A line that already says the same thing
    /// (and includes a year) is left exactly as the user wrote it.
    public static func apply(_ date: TaskDate?, to notes: String, today: Date = Date(), calendar: Calendar = .current) -> String {
        var lines = notes.components(separatedBy: "\n")
        let index = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let existing = index.flatMap { parse(line: lines[$0], today: today, calendar: calendar) }

        if let existing, let index {
            if let date {
                if existing.hadYear && existing.date == date { return notes }
                lines[index] = format(date)
            } else {
                lines.remove(at: index)
                // Drop one blank line left behind under the removed due line.
                if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.remove(at: index)
                }
            }
            return lines.joined(separator: "\n")
        }

        guard let date else { return notes }
        let body = notes.normalizedNotes
        return body.isEmpty ? format(date) : format(date) + "\n" + body
    }

    private static func firstLine(of notes: String) -> String? {
        notes.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
