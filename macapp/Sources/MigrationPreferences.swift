import Foundation

/// The half of the Swarm migration that reaches into the app's own preferences.
/// It is kept apart from `Migration` so that the part which decides what happens
/// to your torrent list stays free of app dependencies and can be tested.
extension Migration {
    private static let oldBundleID = "com.bannawat.swarm"

    static func runIfNeeded() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        carryState(in: support)
        copyPreferences()
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
