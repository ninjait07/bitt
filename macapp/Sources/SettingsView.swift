import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Prefs.askWhereToSave) private var askWhereToSave = false
    @AppStorage(Prefs.askOnAdd) private var askOnAdd = true
    @AppStorage(Prefs.showDockIcon) private var showDockIcon = false

    @State private var draft = EngineSettings()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                downloadFolderRow
                Toggle("Ask before adding a torrent", isOn: $askOnAdd)
                Text(askOnAdd
                     ? "Opening a .torrent or a magnet link brings BITT forward and asks "
                     + "whether to start straight away or add it paused. The folder can be "
                     + "changed there too."
                     : "Torrents are added and start downloading immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !askOnAdd {
                    Toggle("Ask where to save each time", isOn: $askWhereToSave)
                }
            } header: {
                Text("Downloads")
            }

            Section {
                Toggle("Keep seeding after a download finishes", isOn: $draft.seedAfterComplete)
                Text("Seeding shares what you have with other people. "
                   + "Turn it off and a torrent stops as soon as it is complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sharing")
            }

            Section {
                LabeledContent("Maximum download") {
                    HStack(spacing: 6) {
                        TextField("", value: downloadLimitBinding,
                                  format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Maximum upload") {
                    HStack(spacing: 6) {
                        TextField("", value: uploadLimitBinding,
                                  format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                }
                Text("0 means no limit. Capping the upload keeps seeding from "
                   + "eating the whole connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speed")
            }

            Section {
                LabeledContent("Listening port") {
                    TextField("", value: $draft.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                LabeledContent("Maximum peers per torrent") {
                    TextField("", value: $draft.maxPeers, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Toggle("Ask the router to forward this port", isOn: $draft.mapPortAutomatically)
                HStack(spacing: 6) {
                    Text("Router:").foregroundStyle(.secondary)
                    Text(engine.portMapping)
                }
                .font(.caption)
                Text("A new port takes effect the next time BITT starts. "
                   + "Forwarding lets other peers reach you, which is what builds a ratio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Network")
            }

            Section {
                Toggle("Show BITT in the Dock", isOn: $showDockIcon)
                Text("BITT always runs from the menu bar. Turn this on if you also "
                   + "want a Dock icon and a ⌘-Tab entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            }

            HStack {
                Spacer()
                Button("Apply") { engine.apply(settings: draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == engine.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear {
            if !loaded { draft = engine.settings; loaded = true }
        }
        .onChange(of: engine.settings) { newValue in
            // Adopt changes made elsewhere (the menu bar panel, the File menu).
            if draft.downloadDir != newValue.downloadDir { draft.downloadDir = newValue.downloadDir }
        }
        .onChange(of: showDockIcon) { _ in
            WindowManager.shared.applyDockPreference()
        }
    }

    private var downloadLimitBinding: Binding<Double> {
        Binding(get: { EngineSettings.megabytes(fromBytes: draft.downloadLimit) },
                set: { draft.downloadLimit = EngineSettings.bytes(fromMegabytes: $0) })
    }

    private var uploadLimitBinding: Binding<Double> {
        Binding(get: { EngineSettings.megabytes(fromBytes: draft.uploadLimit) },
                set: { draft.uploadLimit = EngineSettings.bytes(fromMegabytes: $0) })
    }

    private var downloadFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save downloads to")
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(displayPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(draft.downloadDir)
                Spacer(minLength: 8)
                Button("Choose…", action: chooseFolder)
                Button("Reveal") { Reveal.open(path: draft.downloadDir) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private var displayPath: String {
        let home = NSHomeDirectory()
        return draft.downloadDir.hasPrefix(home)
            ? "~" + draft.downloadDir.dropFirst(home.count)
            : draft.downloadDir
    }

    private func chooseFolder() {
        guard let folder = AddFlow.chooseFolder(title: "Choose where downloads are saved",
                                                startingAt: draft.downloadDir,
                                                prompt: "Use This Folder") else { return }
        draft.downloadDir = folder
        // A folder choice is a decision, not a draft: apply it straight away.
        engine.apply(settings: draft)
    }
}
