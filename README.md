# TaskSorcerer

Two-way sync between Apple Reminders and Google Tasks, as a macOS menu-bar app
(plus a `sorcerer` command-line tool for setup, previews and debugging).

## What syncs

| | Apple Reminders | Google Tasks |
|---|---|---|
| Title, notes, completed | ⇄ | ⇄ |
| Reminder date | ⇄ | task date (`due`, date only) |

- **Deadlines:** Google Tasks' API only exposes a task's date, not the separate deadline you can
  set in the Google Tasks app, so deadlines can't be synced.
- **Times:** Google Tasks' API stores dates without a time. If only the time changes in Apple,
  nothing is sent to Google. When the day changes in Google, the reminder keeps its time
  (and its alarm moves with it).
- **Conflicts:** if both sides changed *different* fields, both changes are kept. If both changed
  the *same* field, the conflict policy decides (default: most recently edited wins).
- **Deletions** sync both ways. If a task was deleted on one side but edited on the other,
  the edited version wins and is re-created. A sync that would delete more than 10 tasks in a
  list (configurable) is paused until you confirm it.
- **First sync:** tasks with the same title on both sides are paired instead of duplicated.
  Already-completed tasks aren't copied unless you turn that on.
- **Not synced (yet):** subtasks are synced as ordinary tasks, and recurrence, priority,
  flags, tags and URLs aren't synced.

## Build

Requires Xcode (15.2+ is fine on macOS 13). No `xcode-select` change needed. The script uses
`DEVELOPER_DIR` to find Xcode.

```bash
./scripts/build-app.sh                 # → build/TaskSorcerer.app and build/sorcerer
cp -R build/TaskSorcerer.app /Applications/
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The app is ad-hoc signed, so after each rebuild macOS may ask again for Reminders and
keychain access.

## Google setup (one time, ~5 minutes)

Google requires every app that uses the Tasks API to have its own OAuth client. You create one
in your own Google Cloud project, and it's free.

1. Go to <https://console.cloud.google.com/>, create a project (e.g. “TaskSorcerer”).
2. **APIs & Services → Library** → search **Google Tasks API** → **Enable**.
3. **Google Auth Platform → Branding**: app name “TaskSorcerer”, your email as support and
   developer contact.
4. **Audience**: choose **External**, then click **Publish app** (status “In production”).
   In “Testing” status Google expires the sign-in after 7 days, and you'd have to sign in again weekly.
   You don't need verification for personal use. On sign-in you'll see “Google hasn't verified
   this app”. Click **Advanced → Go to TaskSorcerer**.
5. **Clients → Create client** → type **Desktop app** → copy the **Client ID** and **Client secret**.

Then either paste them into the app's Settings and click **Sign in with Google…**, or use the CLI:

```bash
./build/sorcerer google-client "<client-id>" "<client-secret>"
./build/sorcerer auth
```

The refresh token is stored in your login keychain. Config and sync state live in
`~/Library/Application Support/TaskSorcerer/`.

## Using it

Menu-bar app: **Settings…** → add list pairs. Use
**Preview Changes…** to see what a sync would do before letting it run. It syncs every 5 minutes
(configurable) and about 15 seconds after you edit a reminder.

CLI:

```bash
./build/sorcerer lists                          # show both sides' list names
./build/sorcerer pair "Reminders" "My Tasks"
./build/sorcerer sync --dry-run                 # preview
./build/sorcerer sync
```

## Layout

- `Sources/SorcererCore`: sync engine, Google Tasks + OAuth, EventKit.
  It has no UI code, so an iPhone companion app can reuse it.
- `Sources/TaskSorcerer`: SwiftUI menu-bar app.
- `Sources/sorcerer`: CLI.
- `Tests/SorcererCoreTests`: parser and sync-engine tests (run against in-memory lists).
