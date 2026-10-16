import Foundation

public struct PairReport {
    public var pair: ListPair
    /// Human-readable list of changes made (or, in a dry run, that would be made).
    public var changes: [String] = []
    public var errors: [String] = []
    /// Set when the pair was not synced at all, e.g. because the delete safety limit was hit.
    public var skippedReason: String?

    public init(pair: ListPair) {
        self.pair = pair
    }

    public var summary: String {
        if let skippedReason { return "\(pair.label): skipped — \(skippedReason)" }
        let base = changes.isEmpty ? "\(pair.label): up to date" : "\(pair.label): \(changes.count) change(s)"
        return errors.isEmpty ? base : base + ", \(errors.count) error(s)"
    }
}

/// Two-way sync of one list pair using a three-way merge against the snapshot
/// stored at the last sync.
public final class SyncEngine {
    public var config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    // MARK: - Planning types

    enum Write {
        case create(RawTask)
        case update(RawTask)
        case delete(String)
    }

    struct Step {
        var appleID: String?
        var googleID: String?
        var apple: Write?
        var google: Write?
        /// nil when the pairing ends (a deletion).
        var newBase: Snapshot?
        var oldRecord: SyncRecord?
        var changes: [String] = []
    }

    /// A task reduced to the values we compare.
    struct View {
        var title: String
        var notes: String
        var date: TaskDate?
        var completed: Bool

        var snapshot: Snapshot {
            Snapshot(title: title, notes: notes.normalizedNotes, dayKey: date?.dayKey, completed: completed)
        }
    }

    // MARK: - Sync

    /// Syncs one pair and returns the records to store for it. In a dry run nothing is
    /// written and the returned records are the ones passed in.
    public func sync(pair: ListPair, apple: TaskListProvider, google: TaskListProvider,
                     records: [SyncRecord], dryRun: Bool = false, force: Bool = false) async throws
        -> (records: [SyncRecord], report: PairReport)
    {
        let appleTasks = try await apple.fetchTasks()
        let googleTasks = try await google.fetchTasks()
        var report = PairReport(pair: pair)
        let steps = plan(pair: pair, appleTasks: appleTasks, googleTasks: googleTasks, records: records)

        let deletes = steps.reduce(0) { n, s in
            n + (s.apple.map(Self.isDelete) == true ? 1 : 0) + (s.google.map(Self.isDelete) == true ? 1 : 0)
        }
        if deletes > config.maxDeletesPerSync && !force {
            report.skippedReason = "would delete \(deletes) tasks (limit \(config.maxDeletesPerSync)). "
                + "Check the lists, then sync with force if this is intended."
            report.changes = steps.flatMap(\.changes)
            return (records, report)
        }

        if dryRun {
            report.changes = steps.flatMap(\.changes)
            return (records, report)
        }

        var out: [SyncRecord] = []
        for step in steps {
            var appleID = step.appleID
            var googleID = step.googleID
            do {
                if let w = step.apple { appleID = try await perform(w, on: apple) ?? appleID }
                if let w = step.google { googleID = try await perform(w, on: google) ?? googleID }
                if let base = step.newBase, let appleID, let googleID {
                    out.append(SyncRecord(appleID: appleID, googleID: googleID, base: base))
                }
                report.changes += step.changes
            } catch {
                report.errors.append("\(step.changes.first ?? "sync"): \(error.localizedDescription)")
                if let old = step.oldRecord {
                    // Keep the old snapshot so the same change is retried next time.
                    out.append(old)
                } else if let base = step.newBase, let appleID, let googleID {
                    // Both sides exist now; record the pairing so a retry doesn't duplicate the task.
                    out.append(SyncRecord(appleID: appleID, googleID: googleID, base: base))
                }
            }
        }
        return (out, report)
    }

    private static func isDelete(_ w: Write) -> Bool {
        if case .delete = w { return true }
        return false
    }

    /// Performs a write and returns the new id for creates.
    private func perform(_ write: Write, on provider: TaskListProvider) async throws -> String? {
        switch write {
        case .create(let t): return try await provider.create(t).id
        case .update(let t): try await provider.update(t); return nil
        case .delete(let id): try await provider.delete(id: id); return nil
        }
    }

    // MARK: - Planning

    func plan(pair: ListPair, appleTasks: [RawTask], googleTasks: [RawTask], records: [SyncRecord]) -> [Step] {
        let aByID = Dictionary(appleTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gByID = Dictionary(googleTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var usedA = Set<String>()
        var usedG = Set<String>()
        var steps: [Step] = []

        for rec in records {
            let a = aByID[rec.appleID]
            let g = gByID[rec.googleID]
            switch (a, g) {
            case (nil, nil):
                continue
            case let (a?, nil):
                // Deleted in Google. Delete in Apple unless it was edited there since the last sync,
                // in which case it is treated as new and re-created in Google.
                if view(a).snapshot == rec.base {
                    usedA.insert(a.id)
                    steps.append(Step(appleID: a.id, apple: .delete(a.id), oldRecord: rec,
                                      changes: ["✕ Apple: “\(a.title)” (deleted in Google)"]))
                }
            case let (nil, g?):
                if view(g).snapshot == rec.base {
                    usedG.insert(g.id)
                    steps.append(Step(googleID: g.id, google: .delete(g.id), oldRecord: rec,
                                      changes: ["✕ Google: “\(g.title)” (deleted in Apple)"]))
                }
            case let (a?, g?):
                usedA.insert(a.id)
                usedG.insert(g.id)
                steps.append(merge(apple: a, google: g, base: rec.base, oldRecord: rec))
            }
        }

        var unmatchedA = appleTasks.filter { !usedA.contains($0.id) }
        var unmatchedG = googleTasks.filter { !usedG.contains($0.id) && !Self.isBlank($0) }

        // Pair up tasks that already exist on both sides (typically on the first sync)
        // instead of duplicating them.
        for a in unmatchedA {
            let va = view(a)
            let key = Self.matchKey(a.title)
            guard let idx = unmatchedG.firstIndex(where: {
                Self.matchKey($0.title) == key && (va.date == nil || $0.scheduled == nil || $0.scheduled?.dayKey == va.date?.dayKey)
            }) else { continue }
            let g = unmatchedG.remove(at: idx)
            unmatchedA.removeAll { $0.id == a.id }
            steps.append(merge(apple: a, google: g, base: nil, oldRecord: nil))
        }

        for a in unmatchedA where config.copyCompletedTasks || !a.completed {
            steps.append(createFromApple(a))
        }
        for g in unmatchedG where config.copyCompletedTasks || !g.completed {
            steps.append(createFromGoogle(g))
        }
        return steps
    }

    func view(_ t: RawTask) -> View {
        View(title: t.title, notes: t.notes.normalizedNotes, date: t.scheduled, completed: t.completed)
    }

    private func merge(apple a: RawTask, google g: RawTask, base: Snapshot?, oldRecord: SyncRecord?) -> Step {
        let va = view(a)
        let vg = view(g)
        let appleWins: Bool
        switch config.conflictPolicy {
        case .apple: appleWins = true
        case .google: appleWins = false
        case .newest: appleWins = (a.modified ?? .distantPast) >= (g.modified ?? .distantPast)
        }

        func pick<T: Equatable>(_ b: T?, _ x: T, _ y: T) -> T {
            if x == y { return x }
            if let b {
                if x == b { return y }   // only Google changed
                if y == b { return x }   // only Apple changed
            }
            return appleWins ? x : y
        }

        let title = pick(base?.title, va.title, vg.title)
        let notes = pick(base?.notes, va.notes, vg.notes)
        let completed = pick(base?.completed, va.completed, vg.completed)
        let dayKey = pick(base.map { $0.dayKey }, va.date?.dayKey, vg.date?.dayKey)
        let date: TaskDate? = dayKey == nil ? nil : (dayKey == va.date?.dayKey ? va.date : vg.date)

        return buildStep(title: title, notes: notes, date: date, completed: completed,
                         apple: a, google: g, oldRecord: oldRecord)
    }

    private func createFromApple(_ a: RawTask) -> Step {
        let v = view(a)
        return buildStep(title: v.title, notes: v.notes, date: v.date, completed: v.completed,
                         apple: a, google: nil, oldRecord: nil)
    }

    private func createFromGoogle(_ g: RawTask) -> Step {
        let v = view(g)
        return buildStep(title: v.title, notes: v.notes, date: v.date, completed: v.completed,
                         apple: nil, google: g, oldRecord: nil)
    }

    /// Turns the merged values into writes for whichever side differs from them.
    private func buildStep(title: String, notes: String, date: TaskDate?, completed: Bool,
                           apple a: RawTask?, google g: RawTask?, oldRecord: SyncRecord?) -> Step {
        let appleCurrentDate = a?.scheduled
        // Google has no time of day; keep the time Apple already had when only the day moved.
        var date = date
        if let d = date, !d.hasTime, let t = appleCurrentDate, t.hasTime {
            date = d.withTime(hour: t.hour, minute: t.minute)
        }

        let appleTarget = RawTask(id: a?.id ?? "", title: title, notes: notes, scheduled: date, completed: completed)
        let googleTarget = RawTask(id: g?.id ?? "", title: title, notes: notes,
                                   scheduled: date?.dayOnly(), completed: completed)

        var step = Step(appleID: a?.id, googleID: g?.id, oldRecord: oldRecord)
        step.newBase = Snapshot(title: title, notes: notes, dayKey: date?.dayKey, completed: completed)

        if let a {
            let fields = Self.changedFields(a, appleTarget, compareTime: true)
            if !fields.isEmpty {
                step.apple = .update(appleTarget)
                step.changes.append("✎ Apple: “\(title)” (\(fields.joined(separator: ", ")))")
            }
        } else {
            step.apple = .create(appleTarget)
            step.changes.append("＋ Apple: “\(title)”" + (date.map { " [\($0)]" } ?? ""))
        }

        if let g {
            let fields = Self.changedFields(g, googleTarget, compareTime: false)
            if !fields.isEmpty {
                step.google = .update(googleTarget)
                step.changes.append("✎ Google: “\(title)” (\(fields.joined(separator: ", ")))")
            }
        } else {
            step.google = .create(googleTarget)
            step.changes.append("＋ Google: “\(title)”" + (date.map { " [\($0.dayKey)]" } ?? ""))
        }
        return step
    }

    static func changedFields(_ current: RawTask, _ target: RawTask, compareTime: Bool) -> [String] {
        var fields: [String] = []
        if current.title != target.title { fields.append("title") }
        if current.notes.normalizedNotes != target.notes.normalizedNotes { fields.append("notes") }
        if current.completed != target.completed { fields.append(target.completed ? "completed" : "reopened") }
        let dateChanged = compareTime
            ? current.scheduled != target.scheduled
            : current.scheduled?.dayKey != target.scheduled?.dayKey
        if dateChanged { fields.append("date → \(target.scheduled.map(\.description) ?? "none")") }
        return fields
    }

    static func matchKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Google Tasks lets you leave empty rows in a list; those aren't worth syncing.
    static func isBlank(_ t: RawTask) -> Bool {
        t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && t.notes.normalizedNotes.isEmpty
    }
}
