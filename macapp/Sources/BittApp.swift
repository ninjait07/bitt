import AppKit
import SwiftUI

@MainActor
final class AppState {
    static let shared = AppState()
    let engine: Engine

    private init() {
        // The engine opens its support folder the moment it is built, so the
        // old data has to be carried over before that happens. Assigning in the
        // body rather than inline is what guarantees the order.
        Migration.runIfNeeded()
        engine = Engine()
    }
}

@main
struct BittApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = AppState.shared.engine

    var body: some Scene {
        // BITT's home is the menu bar; the main window is opened on demand by
        // WindowManager, which is why there is no window scene here.
        MenuBarExtra {
            MenuBarPanel().environmentObject(engine)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)
        .commands { BittCommands() }

        Settings {
            SettingsView().environmentObject(engine)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Carry the old Swarm data across before anything reads it.
        Migration.runIfNeeded()
        // Decide before any window exists, so no Dock icon flashes.
        NSApp.setActivationPolicy(Prefs.showDockIconValue ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("app launched")

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        AppState.shared.engine.start()
        Notifier.prepare()

        // On a first run, show the window so the app is not invisible.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Prefs.hasLaunchedBefore) {
            defaults.set(true, forKey: Prefs.hasLaunchedBefore)
            WindowManager.shared.showMain()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // the menu bar item is the app; closing a window is not quitting
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowManager.shared.showMain() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.engine.stop()
    }

    // MARK: - Opening torrents from elsewhere

    func application(_ application: NSApplication, open urls: [URL]) {
        AppLog.write("open urls: \(urls.map(\.absoluteString).joined(separator: ", "))")
        AddFlow.addMany(urls.map { $0.isFileURL ? $0.path : $0.absoluteString })
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        AppLog.write("openFile: \(filename)")
        AddFlow.add(filename)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        AppLog.write("openFiles: \(filenames.joined(separator: ", "))")
        AddFlow.addMany(filenames)
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        AppLog.write("url event: \(string)")
        AddFlow.add(string)
    }

}
