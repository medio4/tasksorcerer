import SorcererCore
import SwiftUI

@main
struct TaskSorcererApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.hasError ? "exclamationmark.arrow.triangle.2.circlepath"
                                             : "arrow.triangle.2.circlepath")
        }

        Window("TaskSorcerer Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Sync Details", id: "details") {
            ReportsView(model: model)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        if !model.canSync {
            Text("Set up Google and pick lists in Settings")
        }
        Divider()
        Button("Sync Now") { Task { await model.syncNow() } }
            .keyboardShortcut("s")
            .disabled(!model.canSync || model.isSyncing)
        Button("Preview Changes…") {
            model.previewReports = nil
            show("details")
            Task { await model.preview() }
        }
        .disabled(!model.canSync)
        Button("Sync Details…") { show("details") }
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit TaskSorcerer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ReportsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let isPreview = model.previewReports != nil
        let reports = model.previewReports ?? model.lastReports
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isPreview ? "Preview — nothing has been changed" : "Last sync").font(.headline)
                Spacer()
                if isPreview {
                    Button("Show Last Sync") { model.previewReports = nil }
                }
            }
            List {
                if reports.isEmpty {
                    Text(isPreview ? "Checking…" : "No sync has run yet.").foregroundStyle(.secondary)
                }
                ForEach(reports.indices, id: \.self) { i in
                    let r = reports[i]
                    Section(r.summary) {
                        ForEach(r.changes, id: \.self) { Text($0) }
                        ForEach(r.errors, id: \.self) { Text("⚠︎ " + $0).foregroundStyle(.red) }
                        if r.skippedReason != nil {
                            Button("Sync anyway (allow deletions)") { Task { await model.syncNow(force: true) } }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }
}
