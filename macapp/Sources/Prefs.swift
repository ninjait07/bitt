import AppKit
import Foundation

/// Preferences that belong to the app rather than the torrent engine.
enum Prefs {
    static let showDockIcon = "showDockIcon"
    static let askWhereToSave = "askWhereToSave"
    static let askOnAdd = "askOnAdd"
    static let hasLaunchedBefore = "hasLaunchedBefore"
    static let showDetailPane = "showDetailPane"

    static var showDockIconValue: Bool {
        UserDefaults.standard.bool(forKey: showDockIcon)
    }

    static var askWhereToSaveValue: Bool {
        UserDefaults.standard.bool(forKey: askWhereToSave)
    }

    /// Defaults to on: a torrent arriving from Finder or a browser should not
    /// start moving data before anyone has seen it.
    static var askOnAddValue: Bool {
        UserDefaults.standard.object(forKey: askOnAdd) as? Bool ?? true
    }
}

/// Every route into the app — Finder, a magnet link, a drop, the menu bar —
/// adds torrents through here, so "ask where to save" applies everywhere.
@MainActor
enum AddFlow {
    static func add(_ source: String) {
        let engine = AppState.shared.engine

        if Prefs.askOnAddValue {
            Task { @MainActor in
                let preview = await engine.preview(source: source)
                switch AddTorrentPrompt.run(preview: preview, source: source,
                                            defaultDirectory: engine.settings.downloadDir) {
                case .start(let directory):
                    engine.add(source: source, directory: directory, paused: false)
                case .paused(let directory):
                    engine.add(source: source, directory: directory, paused: true)
                case .cancel:
                    break
                }
            }
            return
        }

        guard Prefs.askWhereToSaveValue else {
            engine.add(source: source)
            return
        }
        guard let folder = chooseFolder(
            title: "Where should this download go?",
            startingAt: engine.settings.downloadDir,
            prompt: "Save Here"
        ) else { return }   // cancelled: nothing is added
        engine.add(source: source, directory: folder)
    }

    /// One prompt per torrent, in order, rather than several stacked at once.
    static func addMany(_ sources: [String]) {
        guard Prefs.askOnAddValue else {
            sources.forEach(add)
            return
        }
        Task { @MainActor in
            let engine = AppState.shared.engine
            for source in sources {
                let preview = await engine.preview(source: source)
                switch AddTorrentPrompt.run(preview: preview, source: source,
                                            defaultDirectory: engine.settings.downloadDir) {
                case .start(let directory):
                    engine.add(source: source, directory: directory, paused: false)
                case .paused(let directory):
                    engine.add(source: source, directory: directory, paused: true)
                case .cancel:
                    continue
                }
            }
        }
    }

    /// A folder picker that also works when the app is living in the menu bar.
    static func chooseFolder(title: String, startingAt path: String,
                             prompt: String = "Choose") -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.level = .modalPanel
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseTorrentFiles() -> [String] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose one or more .torrent files"
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [MainView.torrentType]
        panel.level = .modalPanel
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    static var clipboardMagnet: String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("magnet:") ? trimmed : nil
    }
}
