import AppKit
import SwiftUI

/// BITT lives in the menu bar, so the main window is opened on demand rather
/// than by a SwiftUI scene. This also owns the Dock-icon policy: the app runs
/// as an accessory (menu bar only) until a window needs to be shown.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var mainWindow: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            // willClose fires before the window is actually gone, so check after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Task { @MainActor in self.dropDockIconIfIdle(ignoring: closing) }
            }
        }
    }

    // MARK: - Activation policy

    func applyDockPreference() {
        if Prefs.showDockIconValue {
            NSApp.setActivationPolicy(.regular)
        } else if !hasVisibleWindow() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Only real windows count. The menu bar panel is an untitled utility
    /// window and must not keep the Dock icon alive.
    private func hasVisibleWindow(ignoring: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            window !== ignoring
                && window.isVisible
                && window.styleMask.contains(.titled)
        }
    }

    private func dropDockIconIfIdle(ignoring: NSWindow? = nil) {
        guard !Prefs.showDockIconValue, !hasVisibleWindow(ignoring: ignoring) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func raiseForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Main window

    func showMain() {
        raiseForWindow()
        if mainWindow == nil { buildMainWindow() }
        mainWindow?.makeKeyAndOrderFront(nil)
        if let window = mainWindow {
            // The flattening loop stops when the window closes, so start it again.
            DispatchQueue.main.async { self.unborder(window) }
        }
    }

    private func buildMainWindow() {
        let root = MainView().environmentObject(AppState.shared.engine)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "BITT"
        // The sidebar already carries the logo and the name, so the title bar
        // does not repeat it. The window keeps its title for the Window menu.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1020, height: 640))
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("BittMainWindow")
        if window.frame.origin == .zero { window.center() }
        mainWindow = window

        // SwiftUI installs the toolbar as the hosting view appears, so the
        // compact metrics have to be set once that has happened.
        DispatchQueue.main.async {
            window.toolbar?.displayMode = .iconOnly
            // Compact keeps the title and the buttons on one short row, so the
            // window's top edge stays thin.
            window.toolbarStyle = .unifiedCompact
        }
    }

    /// SwiftUI rebuilds the window chrome whenever the content changes, and each
    /// rebuild brings back the bordered toolbar capsules and the title text, so
    /// keep flattening them.
    private func unborder(_ window: NSWindow) {
        guard window.isVisible else { return }
        window.toolbar?.items.forEach { $0.isBordered = false }
        window.titleVisibility = .hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak window] in
            guard let window, window.isVisible else { return }
            self.unborder(window)
        }
    }

    // MARK: - Settings

    func showSettings() {
        raiseForWindow()
        // The selector was renamed in macOS 13; try the modern one first.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
