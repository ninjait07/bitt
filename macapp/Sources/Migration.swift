import Foundation

/// The app was called Swarm before it was renamed to BITT. Renaming moves both
/// the support folder and the preferences domain, so the torrent list and the
/// settings have to be carried across.
///
/// This works file by file rather than moving the whole folder: the engine may
/// already have created its own folder before this runs, and the old one is
/// left in place as a safety net.
///
/// It must happen exactly once, at the moment of the rename. An earlier version
/// decided by asking whether BITT's list was empty, which is not the same
/// question: delete every torrent and the list is empty too, so the next launch
/// read that as "not migrated yet" and copied the whole old list back. Removed
/// torrents kept coming back. Now a marker file records that the migration has
/// been considered, and the list is only carried when BITT has never written a
/// state file of its own.
enum Migration {
    private static let oldName = "Swarm"
    private static let newName = "BITT"
    private static let markerName = ".migrated-from-swarm"

    /// Carries the list across if this is the first launch under the new name.
    /// Returns whether anything was actually copied. `support` is a parameter so
    /// the tests can run the whole thing inside a temporary directory.
    @discardableResult
    static func carryState(in support: URL,
                           log: (String) -> Void = { AppLog.write($0) }) -> Bool {
        let manager = FileManager.default
        let old = support.appendingPathComponent(oldName)
        let new = support.appendingPathComponent(newName)
        let marker = new.appendingPathComponent(markerName)

        // Asked and answered, whatever the answer was.
        guard !manager.fileExists(atPath: marker.path) else { return false }
        defer { leaveMarker(at: marker, in: new) }

        guard manager.fileExists(atPath: old.path) else { return false }

        let oldState = old.appendingPathComponent("state.json")
        let newState = new.appendingPathComponent("state.json")
        guard manager.fileExists(atPath: oldState.path), listsTorrents(oldState) else { return false }
        // BITT has kept its own list at some point, so it is not a fresh rename.
        // An empty list is a list: it means everything in it was removed.
        guard !manager.fileExists(atPath: newState.path) else { return false }

        try? manager.createDirectory(at: new, withIntermediateDirectories: true)
        do {
            try manager.copyItem(at: oldState, to: newState)
        } catch {
            return false
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
        log("carried the torrent list over from \(oldName)")
        return true
    }

    private static func leaveMarker(at marker: URL, in directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: marker)
    }

    private static func listsTorrents(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let torrents = json["torrents"] as? [Any] else { return false }
        return !torrents.isEmpty
    }
}
