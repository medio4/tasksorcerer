import XCTest
@testable import SorcererCore

/// In-memory stand-in for a Reminders list or Google Tasks list.
final class FakeList: TaskListProvider {
    let displayName: String
    let dayOnly: Bool
    var tasks: [String: RawTask] = [:]
    private var nextID = 0
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(_ name: String, dayOnly: Bool = false) {
        displayName = name
        self.dayOnly = dayOnly
    }

    @discardableResult
    func add(_ t: RawTask) -> String {
        nextID += 1
        var t = t
        t.id = "\(displayName)-\(nextID)"
        if dayOnly { t.scheduled = t.scheduled?.dayOnly() }
        t.modified = tick()
        tasks[t.id] = t
        return t.id
    }

    func edit(_ id: String, _ change: (inout RawTask) -> Void) {
        change(&tasks[id]!)
        tasks[id]!.modified = tick()
    }

    func tick() -> Date {
        clock = clock.addingTimeInterval(60)
        return clock
    }

    var all: [RawTask] { tasks.values.sorted { $0.id < $1.id } }

    func fetchTasks() async throws -> [RawTask] { all }
    func create(_ task: RawTask) async throws -> RawTask { tasks[add(task)]! }
    func update(_ task: RawTask) async throws {
        var t = task
        if dayOnly { t.scheduled = t.scheduled?.dayOnly() }
        t.modified = tick()
        tasks[task.id] = t
    }
    func delete(id: String) async throws { tasks[id] = nil }
}

final class SyncEngineTests: XCTestCase {
    var apple: FakeList!
    var google: FakeList!
    var records: [SyncRecord] = []
    var config = AppConfig()
    var pair = ListPair(appleCalendarID: "a", appleTitle: "Inbox", googleListID: "g", googleTitle: "Inbox")
    let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16))!

    override func setUp() {
        apple = FakeList("apple")
        google = FakeList("google", dayOnly: true)
        records = []
        config = AppConfig()
    }

    @discardableResult
    func sync(dryRun: Bool = false, force: Bool = false) async throws -> PairReport {
        let engine = SyncEngine(config: config, now: { self.today })
        let (r, report) = try await engine.sync(pair: pair, apple: apple, google: google,
                                                records: records, dryRun: dryRun, force: force)
        records = r
        return report
    }

    func testCreatesBothWays() async throws {
        apple.add(RawTask(title: "From Apple", scheduled: TaskDate(year: 2026, month: 10, day: 20, hour: 9, minute: 0)))
        google.add(RawTask(title: "From Google", notes: "hi", scheduled: TaskDate(year: 2026, month: 11, day: 1)))
        try await sync()

        XCTAssertEqual(Set(apple.all.map(\.title)), ["From Apple", "From Google"])
        XCTAssertEqual(Set(google.all.map(\.title)), ["From Apple", "From Google"])
        XCTAssertEqual(google.all.first { $0.title == "From Apple" }?.scheduled, TaskDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(apple.all.first { $0.title == "From Google" }?.notes, "hi")
        XCTAssertEqual(records.count, 2)

        // A second sync is a no-op.
        let report = try await sync()
        XCTAssertTrue(report.changes.isEmpty, "\(report.changes)")
    }

    func testDryRunChangesNothing() async throws {
        apple.add(RawTask(title: "A"))
        let report = try await sync(dryRun: true)
        XCTAssertEqual(report.changes.count, 1)
        XCTAssertTrue(google.all.isEmpty)
        XCTAssertTrue(records.isEmpty)
    }

    func testFirstSyncMatchesExistingTasksInsteadOfDuplicating() async throws {
        apple.add(RawTask(title: "Pay rent", scheduled: TaskDate(year: 2026, month: 11, day: 1)))
        google.add(RawTask(title: "pay rent ", scheduled: TaskDate(year: 2026, month: 11, day: 1)))
        try await sync()
        XCTAssertEqual(apple.all.count, 1)
        XCTAssertEqual(google.all.count, 1)
        XCTAssertEqual(records.count, 1)
    }

    func testGoogleDateChangeKeepsAppleTime() async throws {
        let id = apple.add(RawTask(title: "Call", scheduled: TaskDate(year: 2026, month: 10, day: 20, hour: 15, minute: 30)))
        try await sync()
        let gid = google.all[0].id
        google.edit(gid) { $0.scheduled = TaskDate(year: 2026, month: 10, day: 22) }
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.scheduled, TaskDate(year: 2026, month: 10, day: 22, hour: 15, minute: 30))
    }

    func testAppleTimeOnlyChangeDoesNotTouchGoogle() async throws {
        let id = apple.add(RawTask(title: "Call", scheduled: TaskDate(year: 2026, month: 10, day: 20, hour: 15, minute: 30)))
        try await sync()
        apple.edit(id) { $0.scheduled = TaskDate(year: 2026, month: 10, day: 20, hour: 8, minute: 0) }
        let report = try await sync()
        XCTAssertTrue(report.changes.isEmpty, "\(report.changes)")
    }

    func testFieldLevelMergeWhenBothSidesEdit() async throws {
        let id = apple.add(RawTask(title: "Old title", notes: "old notes"))
        try await sync()
        let gid = google.all[0].id
        apple.edit(id) { $0.title = "New title" }
        google.edit(gid) { $0.notes = "new notes" }
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.title, "New title")
        XCTAssertEqual(apple.tasks[id]?.notes, "new notes")
        XCTAssertEqual(google.tasks[gid]?.title, "New title")
        XCTAssertEqual(google.tasks[gid]?.notes, "new notes")
    }

    func testConflictNewestWins() async throws {
        let id = apple.add(RawTask(title: "Task"))
        try await sync()
        let gid = google.all[0].id
        apple.edit(id) { $0.title = "Apple edit" }
        google.clock = apple.clock.addingTimeInterval(600)
        google.edit(gid) { $0.title = "Google edit (later)" }
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.title, "Google edit (later)")
    }

    func testCompletionSyncs() async throws {
        let id = apple.add(RawTask(title: "Task"))
        try await sync()
        let gid = google.all[0].id
        google.edit(gid) { $0.completed = true }
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.completed, true)
    }

    func testCompletedTasksNotCopiedByDefault() async throws {
        google.add(RawTask(title: "Done long ago", completed: true))
        try await sync()
        XCTAssertTrue(apple.all.isEmpty)
        config.copyCompletedTasks = true
        try await sync()
        XCTAssertEqual(apple.all.count, 1)
    }

    func testDeletionPropagates() async throws {
        let id = apple.add(RawTask(title: "Task"))
        try await sync()
        try await apple.delete(id: id)
        try await sync()
        XCTAssertTrue(google.all.isEmpty)
        XCTAssertTrue(records.isEmpty)
    }

    func testDeletedOnOneSideButEditedOnOtherIsRecreated() async throws {
        let id = apple.add(RawTask(title: "Task"))
        try await sync()
        let gid = google.all[0].id
        try await apple.delete(id: id)
        google.edit(gid) { $0.title = "Task (edited)" }
        try await sync()
        XCTAssertEqual(apple.all.map(\.title), ["Task (edited)"])
        XCTAssertEqual(google.all.count, 1)
    }

    func testDeleteSafetyLimit() async throws {
        config.maxDeletesPerSync = 2
        for i in 0..<5 { apple.add(RawTask(title: "T\(i)")) }
        try await sync()
        google.tasks.removeAll()
        let report = try await sync()
        XCTAssertNotNil(report.skippedReason)
        XCTAssertEqual(apple.all.count, 5)
        try await sync(force: true)
        XCTAssertTrue(apple.all.isEmpty)
    }

    // MARK: Due-line mode

    func testDueModeAppleLineBecomesGoogleDate() async throws {
        pair.dateMode = .due
        apple.add(RawTask(title: "Report", notes: "Due: 10-24-26 5 PM\nDraft first",
                          scheduled: TaskDate(year: 2026, month: 10, day: 20)))
        try await sync()
        let g = google.all[0]
        XCTAssertEqual(g.scheduled, TaskDate(year: 2026, month: 10, day: 24))
        XCTAssertEqual(g.notes, "Due: 10-24-26 5 PM\nDraft first")
    }

    func testDueModeGoogleDateRewritesAppleLineAndKeepsScheduledDate() async throws {
        pair.dateMode = .due
        let scheduled = TaskDate(year: 2026, month: 10, day: 20, hour: 9, minute: 0)
        let id = apple.add(RawTask(title: "Report", notes: "Due: 10-24-26 5:00 PM\nDraft first", scheduled: scheduled))
        try await sync()
        let gid = google.all[0].id
        google.edit(gid) { $0.scheduled = TaskDate(year: 2026, month: 10, day: 27) }
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.notes, "Due: 10-27-26 5:00 PM\nDraft first")
        XCTAssertEqual(apple.tasks[id]?.scheduled, scheduled)
        XCTAssertEqual(google.tasks[gid]?.notes, "Due: 10-27-26 5:00 PM\nDraft first")
        let report = try await sync()
        XCTAssertTrue(report.changes.isEmpty, "\(report.changes)")
    }

    func testDueModeGoogleTaskGetsDueLineInApple() async throws {
        pair.dateMode = .due
        google.add(RawTask(title: "Taxes", notes: "Call accountant", scheduled: TaskDate(year: 2027, month: 4, day: 15)))
        try await sync()
        let a = apple.all[0]
        XCTAssertEqual(a.notes, "Due: 04-15-27\nCall accountant")
        XCTAssertNil(a.scheduled)
        XCTAssertEqual(google.all[0].notes, "Due: 04-15-27\nCall accountant")
    }

    func testScheduledModeLeavesDueLineAsPlainNotes() async throws {
        apple.add(RawTask(title: "Report", notes: "Due: 10-24\nDraft", scheduled: TaskDate(year: 2026, month: 10, day: 20)))
        try await sync()
        XCTAssertEqual(google.all[0].notes, "Due: 10-24\nDraft")
        XCTAssertEqual(google.all[0].scheduled, TaskDate(year: 2026, month: 10, day: 20))
    }

    func testSwitchingToDueModeMovesGoogleDateIntoDueLine() async throws {
        // Synced in scheduled mode first: Google's date became the reminder's date.
        google.add(RawTask(title: "hello", scheduled: TaskDate(year: 2026, month: 10, day: 16)))
        try await sync()
        let id = apple.all[0].id
        let gid = google.all[0].id
        XCTAssertEqual(apple.tasks[id]?.scheduled, TaskDate(year: 2026, month: 10, day: 16))

        // The missing Due line is not a deletion of the date, so Google keeps it.
        pair.dateMode = .due
        try await sync()
        XCTAssertEqual(apple.tasks[id]?.notes, "Due: 10-16-26")
        XCTAssertEqual(google.tasks[gid]?.scheduled, TaskDate(year: 2026, month: 10, day: 16))
        let report = try await sync()
        XCTAssertTrue(report.changes.isEmpty, "\(report.changes)")

        // After the switch, removing the Due line does clear Google's date.
        apple.edit(id) { $0.notes = "" }
        try await sync()
        XCTAssertNil(google.tasks[gid]?.scheduled)
    }

    func testSwitchingToDueModeWithRecordsFromBeforeModesWereStored() async throws {
        google.add(RawTask(title: "hello", scheduled: TaskDate(year: 2026, month: 10, day: 16)))
        try await sync()
        records = records.map { var r = $0; r.dateMode = nil; return r }
        pair.dateMode = .due
        try await sync()
        XCTAssertEqual(apple.all[0].notes, "Due: 10-16-26")
        XCTAssertEqual(google.all[0].scheduled, TaskDate(year: 2026, month: 10, day: 16))
    }

    func testSwitchingToScheduledModeMovesDueLineIntoReminderDate() async throws {
        pair.dateMode = .due
        let id = apple.add(RawTask(title: "Report", notes: "Due: 10-24-26\nDraft"))
        try await sync()
        let gid = google.all[0].id
        pair.dateMode = .scheduled
        try await sync()
        XCTAssertEqual(google.tasks[gid]?.scheduled, TaskDate(year: 2026, month: 10, day: 24))
        XCTAssertEqual(apple.tasks[id]?.scheduled, TaskDate(year: 2026, month: 10, day: 24))
    }
}
