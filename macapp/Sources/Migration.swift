import Foundation

/// The app was called Swarm before it was renamed to BITT. Renaming moves both
/// the support folder and the preferences domain, so the torrent list and the
/// settings have to be carried across.
///
/// This works file by file rather than moving the whole folder: the engine may
/// already have created its own folder before this runs, and the old one is
/// left in place as a safety net.
enum Migration {
    private static let oldName = "Swarm"
    private static let newName = "BITT"
    private static let oldBundleID = "com.bannawat.swarm"

    static func runIfNeeded() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        carryState(from: support.appendingPathComponent(oldName),
                   to: support.appendingPathComponent(newName))
        copyPreferences()
    }

    private static func carryState(from old: URL, to new: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return }

        let oldState = old.appendingPathComponent("state.json")
        let newState = new.appendingPathComponent("state.json")
        guard manager.fileExists(atPath: oldState.path), listsTorrents(oldState) else { return }
        // Never overwrite a list that already has something in it.
        guard !listsTorrents(newState) else { return }

        try? manager.createDirectory(at: new, withIntermediateDirectories: true)
        try? manager.removeItem(at: newState)
        do {
            try manager.copyItem(at: oldState, to: newState)
        } catch {
            return
        }

        // The cached .torrent files are what the list points at.
        let oldCache = old.appendingPathComponent("torrents")
        let newCache = new.appendingPathComponent("torrents")
        try? manager.createDirectory(at: newCache, withIntermediateDirectories: true)
        for name in (try? manager.contentsOfDirectory(atPath: oldCache.path)) ?? [] {
            let target = newCache.appendingPathComponent(name)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.copyItem(at: oldCache.appendingPathComponent(name), to: target)
        }
        AppLog.write("carried the torrent list over from \(oldName)")
    }

    private static func listsTorrents(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let torrents = json["torrents"] as? [Any] else { return false }
        return !torrents.isEmpty
    }

    private static func copyPreferences() {
        let defaults = UserDefaults.standard
        // Only on the very first run under the new name.
        guard defaults.object(forKey: Prefs.hasLaunchedBefore) == nil,
              let previous = UserDefaults(suiteName: oldBundleID) else { return }
        for key in [Prefs.showDockIcon, Prefs.askWhereToSave, Prefs.askOnAdd,
                    Prefs.showDetailPane, Prefs.hasLaunchedBefore] {
            if let value = previous.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }
}
