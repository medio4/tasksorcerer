import AppKit
import Foundation
import SorcererCore

let usage = """
sorcerer — sync Apple Reminders with Google Tasks

  sorcerer google-client <client-id> <client-secret>   Save your Google OAuth client (see README)
  sorcerer auth                                         Sign in to Google in the browser
  sorcerer signout                                      Forget the Google sign-in
  sorcerer lists                                        Show Reminders lists and Google Tasks lists
  sorcerer pair "<Reminders list>" "<Google list>"
  sorcerer unpair "<Reminders list>"                    Stop syncing a Reminders list
  sorcerer pairs                                        Show synced list pairs
  sorcerer set <conflict newest|apple|google | copy-completed on|off | max-deletes N>
  sorcerer sync [--dry-run] [--force]                   Sync now (--dry-run only shows the changes)
"""

let storage = Storage()
let coordinator = SyncCoordinator(storage: storage)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func findList(_ name: String, in lists: [ListInfo]) -> ListInfo {
    if let exact = lists.first(where: { $0.title == name }) { return exact }
    if let loose = lists.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return loose }
    fail("No list named “\(name)”. Run `sorcerer lists` to see the names.")
}

func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(usage); return }
    var config = try storage.loadConfig()

    switch command {
    case "google-client":
        guard args.count == 3 else { fail(usage) }
        config.googleClientID = args[1]
        config.googleClientSecret = args[2]
        try storage.saveConfig(config)
        print("Saved. Next: sorcerer auth")

    case "auth":
        guard config.hasGoogleClient else { throw SorcererError.missingGoogleClient }
        coordinator.refreshGoogleClient(for: config)
        print("Opening your browser to sign in to Google…")
        try await coordinator.auth.signIn { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        print("Signed in to Google Tasks.")

    case "signout":
        await coordinator.auth.signOut()
        print("Signed out.")

    case "lists":
        try await coordinator.reminders.requestAccess()
        print("Apple Reminders lists:")
        for l in coordinator.reminders.lists() { print("  • \(l.title)" + (l.detail.map { "  (\($0))" } ?? "")) }
        coordinator.refreshGoogleClient(for: config)
        print("\nGoogle Tasks lists:")
        for l in try await coordinator.google.lists() { print("  • \(l.title)") }

    case "pair":
        guard args.count >= 3 else { fail(usage) }
        try await coordinator.reminders.requestAccess()
        coordinator.refreshGoogleClient(for: config)
        let apple = findList(args[1], in: coordinator.reminders.lists())
        let google = findList(args[2], in: try await coordinator.google.lists())
        config.pairs.removeAll { $0.appleCalendarID == apple.id || $0.googleListID == google.id }
        let pair = ListPair(appleCalendarID: apple.id, appleTitle: apple.title,
                            googleListID: google.id, googleTitle: google.title)
        config.pairs.append(pair)
        try storage.saveConfig(config)
        print("Paired \(pair.label). Try: sorcerer sync --dry-run")

    case "unpair":
        guard args.count == 2 else { fail(usage) }
        let before = config.pairs.count
        config.pairs.removeAll { $0.appleTitle.localizedCaseInsensitiveCompare(args[1]) == .orderedSame }
        try storage.saveConfig(config)
        print(before == config.pairs.count ? "No pair for “\(args[1])”." : "Unpaired “\(args[1])”.")

    case "pairs":
        if config.pairs.isEmpty { print("No lists paired yet. Use `sorcerer pair`.") }
        for p in config.pairs {
            print("  \(p.enabled ? "●" : "○") \(p.label)")
        }
        print("\nConflicts: \(config.conflictPolicy.label) · copy completed: \(config.copyCompletedTasks ? "on" : "off")"
              + " · max deletes per sync: \(config.maxDeletesPerSync)")

    case "set":
        guard args.count == 3 else { fail(usage) }
        switch args[1] {
        case "conflict":
            guard let p = ConflictPolicy(rawValue: args[2]) else { fail("conflict must be newest, apple or google") }
            config.conflictPolicy = p
        case "copy-completed":
            config.copyCompletedTasks = args[2] == "on"
        case "max-deletes":
            guard let n = Int(args[2]), n >= 0 else { fail("max-deletes must be a number") }
            config.maxDeletesPerSync = n
        default:
            fail(usage)
        }
        try storage.saveConfig(config)
        print("Saved.")

    case "sync":
        let dryRun = args.contains("--dry-run")
        let reports = try await coordinator.sync(dryRun: dryRun, force: args.contains("--force"))
        if reports.isEmpty { print("No list pairs enabled. Use `sorcerer pair`.") }
        for r in reports {
            print((dryRun ? "[dry run] " : "") + r.summary)
            for c in r.changes { print("    \(c)") }
            for e in r.errors { print("    ⚠︎ \(e)") }
        }

    default:
        print(usage)
    }
}

Task {
    do {
        try await run()
        exit(0)
    } catch {
        fail("Error: \(error.localizedDescription)")
    }
}
RunLoop.main.run()
