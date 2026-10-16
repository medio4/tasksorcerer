import AppKit
import EventKit
import ServiceManagement
import SorcererCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let coordinator = SyncCoordinator()

    @Published var config: AppConfig
    @Published var isSyncing = false
    @Published var status = "Not synced yet"
    @Published var hasError = false
    @Published var lastReports: [PairReport] = []
    @Published var previewReports: [PairReport]?
    @Published var signedIn = false
    @Published var appleLists: [ListInfo] = []
    @Published var googleLists: [ListInfo] = []
    @Published var listsError: String?

    private var timer: Timer?
    private var debounce: Task<Void, Never>?

    init() {
        config = (try? coordinator.storage.loadConfig()) ?? AppConfig()
        signedIn = coordinator.auth.isSignedIn
        if let last = try? coordinator.storage.loadState().lastSync {
            status = "Last synced \(last.formatted(date: .omitted, time: .shortened))"
        }
        restartTimer()

        // Sync shortly after Reminders changes (debounced, since one edit can fire several notifications).
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: coordinator.reminders.store,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleSoonSync() }
        }
        Task { await syncNow() }
    }

    var canSync: Bool { config.hasGoogleClient && signedIn && config.pairs.contains(where: \.enabled) }

    func save() {
        try? coordinator.storage.saveConfig(config)
        coordinator.refreshGoogleClient(for: config)
        signedIn = coordinator.auth.isSignedIn
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, config.syncIntervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
    }

    private func scheduleSoonSync() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    func syncNow(force: Bool = false) async {
        guard canSync, !isSyncing else { return }
        isSyncing = true
        status = "Syncing…"
        defer { isSyncing = false }
        do {
            let reports = try await coordinator.sync(force: force)
            lastReports = reports
            let changes = reports.reduce(0) { $0 + $1.changes.count }
            let problems = reports.filter { !$0.errors.isEmpty || $0.skippedReason != nil }
            hasError = !problems.isEmpty
            let time = Date().formatted(date: .omitted, time: .shortened)
            status = problems.isEmpty
                ? "Synced at \(time)" + (changes > 0 ? " · \(changes) change(s)" : "")
                : "Problem syncing at \(time) — see details"
        } catch {
            hasError = true
            status = error.localizedDescription
        }
    }

    func preview() async {
        do {
            previewReports = try await coordinator.sync(dryRun: true)
        } catch {
            var r = PairReport(pair: ListPair(appleCalendarID: "", appleTitle: "Preview", googleListID: "", googleTitle: "failed"))
            r.errors = [error.localizedDescription]
            previewReports = [r]
        }
    }

    func signIn() async {
        save()
        do {
            try await coordinator.auth.signIn { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            signedIn = true
            await loadLists()
        } catch {
            listsError = error.localizedDescription
        }
    }

    func signOut() async {
        await coordinator.auth.signOut()
        signedIn = false
        googleLists = []
    }

    func loadLists() async {
        listsError = nil
        do {
            try await coordinator.reminders.requestAccess()
            appleLists = coordinator.reminders.lists()
            if signedIn { googleLists = try await coordinator.google.lists() }
        } catch {
            listsError = error.localizedDescription
        }
    }

    func addPair() {
        guard let apple = appleLists.first(where: { a in !config.pairs.contains { $0.appleCalendarID == a.id } }) ?? appleLists.first,
              let google = googleLists.first(where: { $0.title == apple.title }) ?? googleLists.first else { return }
        config.pairs.append(ListPair(appleCalendarID: apple.id, appleTitle: apple.title,
                                     googleListID: google.id, googleTitle: google.title))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}
