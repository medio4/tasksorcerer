import Foundation

/// A calendar day with an optional time of day. Google Tasks only keeps the day,
/// so sync comparisons use `dayKey` and the time is preserved on the Apple side.
public struct TaskDate: Codable, Hashable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int?
    public var minute: Int?

    public init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// "2026-10-20" — the part of the date both services agree on.
    public var dayKey: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var hasTime: Bool { hour != nil }

    public func withTime(hour: Int?, minute: Int?) -> TaskDate {
        TaskDate(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    public func dayOnly() -> TaskDate { withTime(hour: nil, minute: nil) }

    /// Parses the date portion of an RFC 3339 string such as "2026-10-20T00:00:00.000Z".
    public init?(rfc3339DayPrefix string: String) {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var description: String {
        if let hour {
            return dayKey + String(format: " %02d:%02d", hour, minute ?? 0)
        }
        return dayKey
    }
}

/// Which field of an Apple reminder is synced with Google's (date-only, "scheduled") date.
public enum DateMode: String, Codable, CaseIterable, Identifiable {
    /// The reminder's own date (what puts it in Reminders' "Scheduled" list).
    case scheduled
    /// The "Due: MM-DD-YY" line at the top of the reminder's notes.
    case due

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .scheduled: return "Scheduled date"
        case .due: return "Due line in notes"
        }
    }
}

/// What to do when both sides changed the same field since the last sync.
public enum ConflictPolicy: String, Codable, CaseIterable, Identifiable {
    case newest, apple, google

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .newest: return "Most recently edited wins"
        case .apple: return "Apple Reminders wins"
        case .google: return "Google Tasks wins"
        }
    }
}

/// A task as either service sees it, reduced to the fields we sync.
/// `scheduled` is the service's native date (Apple's reminder date, Google's `due`).
public struct RawTask: Equatable {
    public var id: String
    public var title: String
    public var notes: String
    public var scheduled: TaskDate?
    public var completed: Bool
    public var modified: Date?

    public init(id: String = "", title: String, notes: String = "", scheduled: TaskDate? = nil,
                completed: Bool = false, modified: Date? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.scheduled = scheduled
        self.completed = completed
        self.modified = modified
    }
}

/// One list on one side of the sync. Implemented for EventKit and Google Tasks,
/// and by an in-memory fake in tests.
public protocol TaskListProvider: AnyObject {
    var displayName: String { get }
    func fetchTasks() async throws -> [RawTask]
    /// Returns the created task, including its new id.
    func create(_ task: RawTask) async throws -> RawTask
    func update(_ task: RawTask) async throws
    func delete(id: String) async throws
}

public struct ListInfo: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

extension String {
    /// Notes are compared without leading/trailing whitespace, since each service trims differently.
    var normalizedNotes: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
