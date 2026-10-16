import SorcererCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            googleSection
            listsSection
            behaviorSection
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .frame(minHeight: 560)
        .task { await model.loadLists() }
        .onChange(of: model.config) { _ in model.save() }
    }

    private var googleSection: some View {
        Section {
            TextField("OAuth client ID", text: $model.config.googleClientID)
            SecureField("OAuth client secret", text: $model.config.googleClientSecret)
            HStack {
                if model.signedIn {
                    Label("Signed in to Google Tasks", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") { Task { await model.signOut() } }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign in with Google…") { Task { await model.signIn() } }
                        .disabled(!model.config.hasGoogleClient)
                }
            }
        } header: {
            Text("Google account")
        } footer: {
            Text("Use a “Desktop app” OAuth client from your own Google Cloud project. See the README for the 5-minute setup.")
        }
    }

    private var listsSection: some View {
        Section {
            if let error = model.listsError {
                Text(error).foregroundStyle(.red)
            }
            ForEach($model.config.pairs) { $pair in
                PairRow(pair: $pair, appleLists: model.appleLists, googleLists: model.googleLists) {
                    model.config.pairs.removeAll { $0.id == pair.id }
                }
            }
            HStack {
                Button("Add List Pair") { model.addPair() }
                    .disabled(model.appleLists.isEmpty || model.googleLists.isEmpty)
                Spacer()
                Button("Reload Lists") { Task { await model.loadLists() } }
            }
        } header: {
            Text("Synced lists")
        } footer: {
            Text("“Scheduled date” syncs the reminder's date with the Google task's date. "
                 + "“Due line in notes” syncs the Google date with a “Due: MM-DD-YY” line at the top of the reminder's notes instead.")
        }
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            Picker("When both sides changed", selection: $model.config.conflictPolicy) {
                ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Copy tasks that are already completed", isOn: $model.config.copyCompletedTasks)
            Stepper("Sync every \(model.config.syncIntervalMinutes) min",
                    value: $model.config.syncIntervalMinutes, in: 1...120)
            Stepper("Pause if a sync would delete more than \(model.config.maxDeletesPerSync) tasks",
                    value: $model.config.maxDeletesPerSync, in: 0...500)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }
    }
}

struct PairRow: View {
    @Binding var pair: ListPair
    let appleLists: [ListInfo]
    let googleLists: [ListInfo]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $pair.enabled).labelsHidden()
                Picker("Reminders", selection: Binding(
                    get: { pair.appleCalendarID },
                    set: { id in
                        pair.appleCalendarID = id
                        pair.appleTitle = appleLists.first { $0.id == id }?.title ?? pair.appleTitle
                    })) {
                    ForEach(options(appleLists, current: pair.appleCalendarID, title: pair.appleTitle)) { Text($0.title).tag($0.id) }
                }
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Picker("Google", selection: Binding(
                    get: { pair.googleListID },
                    set: { id in
                        pair.googleListID = id
                        pair.googleTitle = googleLists.first { $0.id == id }?.title ?? pair.googleTitle
                    })) {
                    ForEach(options(googleLists, current: pair.googleListID, title: pair.googleTitle)) { Text($0.title).tag($0.id) }
                }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            Picker("Sync Google's date with", selection: $pair.dateMode) {
                ForEach(DateMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    /// Keeps the saved list selectable even before the lists have loaded.
    private func options(_ lists: [ListInfo], current: String, title: String) -> [ListInfo] {
        lists.contains { $0.id == current } ? lists : [ListInfo(id: current, title: title)] + lists
    }
}
