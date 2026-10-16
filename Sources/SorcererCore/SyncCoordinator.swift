import Foundation

/// Runs a full sync over every enabled list pair, loading and saving config/state.
/// Shared by the menu-bar app and the `sorcerer` command-line tool.
public final class SyncCoordinator {
    public let storage: Storage
    public let reminders: RemindersStore
    public private(set) var auth: GoogleAuth
    public private(set) var google: GoogleTasksClient
    private var clientKey: String

    public init(storage: Storage = Storage(), reminders: RemindersStore = RemindersStore()) {
        self.storage = storage
        self.reminders = reminders
        let config = (try? storage.loadConfig()) ?? AppConfig()
        clientKey = config.googleClientID + "|" + config.googleClientSecret
        auth = GoogleAuth(clientID: config.googleClientID, clientSecret: config.googleClientSecret)
        google = GoogleTasksClient(auth: auth)
    }

    /// Recreates the Google client when the OAuth client ID/secret change.
    public func refreshGoogleClient(for config: AppConfig) {
        let key = config.googleClientID + "|" + config.googleClientSecret
        guard key != clientKey else { return }
        clientKey = key
        auth = GoogleAuth(clientID: config.googleClientID, clientSecret: config.googleClientSecret)
        google = GoogleTasksClient(auth: auth)
    }

    public func sync(dryRun: Bool = false, force: Bool = false) async throws -> [PairReport] {
        let config = try storage.loadConfig()
        refreshGoogleClient(for: config)
        guard config.hasGoogleClient else { throw SorcererError.missingGoogleClient }
        guard auth.isSignedIn else { throw SorcererError.notSignedIn }
        try await reminders.requestAccess()

        var state = try storage.loadState()
        let engine = SyncEngine(config: config)
        var reports: [PairReport] = []

        for pair in config.pairs where pair.enabled {
            let key = pair.id.uuidString
            do {
                let apple = try reminders.provider(calendarID: pair.appleCalendarID)
                let googleList = google.provider(listID: pair.googleListID, title: pair.googleTitle)
                let (records, report) = try await engine.sync(pair: pair, apple: apple, google: googleList,
                                                              records: state.pairs[key] ?? [],
                                                              dryRun: dryRun, force: force)
                reports.append(report)
                if !dryRun {
                    state.pairs[key] = records
                    try storage.saveState(state)   // save after each pair so progress isn't lost
                }
            } catch {
                var report = PairReport(pair: pair)
                report.errors.append(error.localizedDescription)
                reports.append(report)
            }
        }

        // Forget state for pairs that were removed.
        let live = Set(config.pairs.map { $0.id.uuidString })
        state.pairs = state.pairs.filter { live.contains($0.key) }
        if !dryRun {
            state.lastSync = Date()
            try storage.saveState(state)
        }
        return reports
    }
}
