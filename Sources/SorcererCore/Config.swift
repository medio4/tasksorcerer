import Foundation

/// An Apple Reminders list synced with a Google Tasks list.
public struct ListPair: Codable, Identifiable, Hashable {
    public var id: UUID
    public var appleCalendarID: String
    public var appleTitle: String
    public var googleListID: String
    public var googleTitle: String
    public var enabled: Bool

    public init(id: UUID = UUID(), appleCalendarID: String, appleTitle: String,
                googleListID: String, googleTitle: String, enabled: Bool = true) {
        self.id = id
        self.appleCalendarID = appleCalendarID
        self.appleTitle = appleTitle
        self.googleListID = googleListID
        self.googleTitle = googleTitle
        self.enabled = enabled
    }

    public var label: String { "\(appleTitle) ⇄ \(googleTitle)" }
}

public struct AppConfig: Codable, Equatable {
    /// OAuth "Desktop app" client from your own Google Cloud project (see README).
    public var googleClientID: String = ""
    public var googleClientSecret: String = ""
    public var pairs: [ListPair] = []
    public var conflictPolicy: ConflictPolicy = .newest
    /// When false, tasks that are already completed aren't copied to the other side
    /// (completion changes on tasks that are already synced always sync).
    public var copyCompletedTasks: Bool = false
    public var syncIntervalMinutes: Int = 5
    /// Safety valve: a list pair whose sync would delete more than this many tasks is skipped.
    public var maxDeletesPerSync: Int = 10

    public init() {}

    public init(from decoder: Decoder) throws {
        // Decode leniently so new settings get defaults in older config files.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? d.googleClientID
        googleClientSecret = try c.decodeIfPresent(String.self, forKey: .googleClientSecret) ?? d.googleClientSecret
        pairs = try c.decodeIfPresent([ListPair].self, forKey: .pairs) ?? d.pairs
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? d.conflictPolicy
        copyCompletedTasks = try c.decodeIfPresent(Bool.self, forKey: .copyCompletedTasks) ?? d.copyCompletedTasks
        syncIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? d.syncIntervalMinutes
        maxDeletesPerSync = try c.decodeIfPresent(Int.self, forKey: .maxDeletesPerSync) ?? d.maxDeletesPerSync
    }

    public var hasGoogleClient: Bool {
        !googleClientID.isEmpty && !googleClientSecret.isEmpty
    }
}

/// What both sides looked like after the last successful sync of a task.
/// Comparing each side to this is how we tell edits and deletions apart from conflicts.
public struct Snapshot: Codable, Equatable {
    public var title: String
    public var notes: String
    public var dayKey: String?
    public var completed: Bool
}

public struct SyncRecord: Codable, Equatable {
    public var appleID: String
    public var googleID: String
    public var base: Snapshot
}

public struct SyncState: Codable, Equatable {
    /// Keyed by `ListPair.id`.
    public var pairs: [String: [SyncRecord]] = [:]
    public var lastSync: Date?

    public init() {}
}

/// Reads and writes config.json and state.json in ~/Library/Application Support/TaskSorcerer.
public struct Storage {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskSorcerer", isDirectory: true)
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var stateURL: URL { directory.appendingPathComponent("state.json") }

    public func loadConfig() throws -> AppConfig { try load(AppConfig.self, from: configURL) ?? AppConfig() }
    public func saveConfig(_ config: AppConfig) throws { try save(config, to: configURL) }
    public func loadState() throws -> SyncState { try load(SyncState.self, from: stateURL) ?? SyncState() }
    public func saveState(_ state: SyncState) throws { try save(state, to: stateURL) }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
