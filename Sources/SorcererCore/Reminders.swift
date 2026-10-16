import EventKit
import Foundation

/// Access to Apple Reminders through EventKit.
public final class RemindersStore {
    public let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws {
        let granted: Bool
        if #available(macOS 14.0, iOS 17.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: .reminder)
        }
        guard granted else { throw SorcererError.remindersAccessDenied }
    }

    public func lists() -> [ListInfo] {
        store.calendars(for: .reminder)
            .map { ListInfo(id: $0.calendarIdentifier, title: $0.title, detail: $0.source.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func provider(calendarID: String) throws -> RemindersListProvider {
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw SorcererError.listNotFound(calendarID)
        }
        return RemindersListProvider(store: store, calendar: calendar)
    }
}

public final class RemindersListProvider: TaskListProvider {
    let store: EKEventStore
    let calendar: EKCalendar
    public var displayName: String { "Apple: \(calendar.title)" }

    init(store: EKEventStore, calendar: EKCalendar) {
        self.store = store
        self.calendar = calendar
    }

    public func fetchTasks() async throws -> [RawTask] {
        let predicate = store.predicateForReminders(in: [calendar])
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.map(Self.raw)
    }

    public func create(_ task: RawTask) async throws -> RawTask {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        apply(task, to: reminder)
        try store.save(reminder, commit: true)
        return Self.raw(reminder)
    }

    public func update(_ task: RawTask) async throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw SorcererError.listNotFound("reminder \(task.id)")
        }
        apply(task, to: reminder)
        try store.save(reminder, commit: true)
    }

    public func delete(id: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    static func raw(_ r: EKReminder) -> RawTask {
        RawTask(
            id: r.calendarItemIdentifier,
            title: r.title ?? "",
            notes: r.notes ?? "",
            scheduled: r.dueDateComponents.flatMap(taskDate),
            completed: r.isCompleted,
            modified: r.lastModifiedDate
        )
    }

    static func taskDate(_ c: DateComponents) -> TaskDate? {
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return TaskDate(year: y, month: m, day: d, hour: c.hour, minute: c.hour == nil ? nil : (c.minute ?? 0))
    }

    private func apply(_ task: RawTask, to r: EKReminder) {
        r.title = task.title
        r.notes = task.notes.isEmpty ? nil : task.notes
        if r.isCompleted != task.completed { r.isCompleted = task.completed }

        let oldDue = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let newComps = task.scheduled.map { d -> DateComponents in
            var c = DateComponents(year: d.year, month: d.month, day: d.day)
            if let h = d.hour { c.hour = h; c.minute = d.minute ?? 0 }
            c.calendar = Calendar.current
            return c
        }
        if r.dueDateComponents.flatMap(Self.taskDate) != task.scheduled {
            r.dueDateComponents = newComps
            moveAlarms(of: r, from: oldDue, to: newComps.flatMap { Calendar.current.date(from: $0) })
        }
    }

    /// Reminders' date alarms are absolute; when the date moves, move the alarm that
    /// fired at the old date so the notification follows the reminder.
    private func moveAlarms(of r: EKReminder, from old: Date?, to new: Date?) {
        guard let old, let alarms = r.alarms else { return }
        for alarm in alarms where alarm.absoluteDate.map({ abs($0.timeIntervalSince(old)) < 60 }) == true {
            r.removeAlarm(alarm)
            if let new { r.addAlarm(EKAlarm(absoluteDate: new)) }
        }
    }
}
