import AppKit
import SwiftUI

/// Menus for the app. SwiftUI rebuilds the main menu whenever a scene updates —
/// which for BITT is every second — so the menus have to be declared here
/// rather than assembled as an NSMenu.
struct BittCommands: Commands {
    @AppStorage(Prefs.showDetailPane) private var showDetailPane = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Torrent File…") {
                AddFlow.addMany(AddFlow.chooseTorrentFiles())
            }
            .keyboardShortcut("o")

            Button("Add Magnet from Clipboard") {
                if let magnet = AddFlow.clipboardMagnet {
                    AddFlow.add(magnet)
                } else {
                    NSSound.beep()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        // Without these the magnet field has no ⌘V, because a menu-bar app
        // gets no Edit menu of its own.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c")
            Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v")
            Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a")
        }

        CommandGroup(after: .sidebar) {
            Button(showDetailPane ? "Hide Details" : "Show Details") {
                showDetailPane.toggle()
            }
            .keyboardShortcut("i")
        }

        CommandMenu("Transfers") {
            Button("Pause All") { AppState.shared.engine.pauseAll() }
                .keyboardShortcut(".")
            Button("Resume All") { AppState.shared.engine.resumeAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("Open Download Folder") {
                Reveal.open(path: AppState.shared.engine.settings.downloadDir)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Change Download Folder…") {
                let engine = AppState.shared.engine
                guard let folder = AddFlow.chooseFolder(
                    title: "Choose where downloads are saved",
                    startingAt: engine.settings.downloadDir,
                    prompt: "Use This Folder"
                ) else { return }
                var updated = engine.settings
                updated.downloadDir = folder
                engine.apply(settings: updated)
            }
        }

        CommandGroup(after: .windowList) {
            Button("BITT Window") { WindowManager.shared.showMain() }
                .keyboardShortcut("1")
        }

        CommandGroup(replacing: .help) {
            Button("BITT Help") {
                if let readme = Bundle.main.url(forResource: "HELP", withExtension: "md") {
                    NSWorkspace.shared.open(readme)
                }
            }
        }
    }
}
