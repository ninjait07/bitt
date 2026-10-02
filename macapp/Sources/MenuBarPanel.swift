import AppKit
import SwiftUI

/// What drops down from the menu bar icon: the whole app in a small panel.
struct MenuBarPanel: View {
    @EnvironmentObject private var engine: Engine
    private var hasTorrents: Bool { !engine.torrents.isEmpty }
    private var anythingRunning: Bool { engine.torrents.contains { !$0.paused } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if hasTorrents {
                transferList
            } else {
                emptyState
            }

            Divider()
            actions
        }
        .frame(width: 360)
        .modifier(GlassPanel())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("BITT").fontWeight(.semibold)
                Text(engineSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Label(Format.rate(engine.totalDownloadRate), systemImage: "arrow.down")
                    .foregroundStyle(engine.totalDownloadRate > 1024
                                     ? Theme.downloading : Color.secondary)
                Label(Format.rate(engine.totalUploadRate), systemImage: "arrow.up")
                    .foregroundStyle(engine.totalUploadRate > 1024
                                     ? Theme.seeding : Color.secondary)
            }
            .font(.caption)
            .monospacedDigit()
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var engineSummary: String {
        switch engine.status {
        case .starting: return "Starting the engine…"
        case .failed: return "The engine is not running"
        case .running:
            if !hasTorrents { return "Idle · port \(engine.listenPort)" }
            let active = engine.activeCount
            return active == 0
                ? "\(engine.torrents.count) torrents · none active"
                : "\(active) active of \(engine.torrents.count)"
        }
    }

    // MARK: - Transfers

    private var transferList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(engine.torrents) { torrent in
                    CompactRow(torrent: torrent)
                    if torrent.id != engine.torrents.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxHeight: 270)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No torrents yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add a .torrent file or a magnet link below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 0) {
            PanelButton(title: "Add Torrent File…", symbol: "plus") {
                dismiss()
                AddFlow.addMany(AddFlow.chooseTorrentFiles())
            }

            PanelButton(title: "Add Magnet from Clipboard",
                        symbol: "link",
                        enabled: AddFlow.clipboardMagnet != nil) {
                if let magnet = AddFlow.clipboardMagnet {
                    dismiss()
                    AddFlow.add(magnet)
                }
            }

            PanelDivider()

            if anythingRunning {
                PanelButton(title: "Pause All", symbol: "pause") { engine.pauseAll() }
            } else {
                PanelButton(title: "Resume All", symbol: "play",
                            enabled: hasTorrents) { engine.resumeAll() }
            }

            PanelDivider()

            PanelButton(title: "Open Download Folder", symbol: "folder") {
                Reveal.open(path: engine.settings.downloadDir)
            }

            PanelDivider()

            PanelButton(title: "Open Main Window", symbol: "macwindow") {
                dismiss()
                WindowManager.shared.showMain()
            }
            PanelButton(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                dismiss()
                WindowManager.shared.showSettings()
            }
            PanelButton(title: "Quit BITT", symbol: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 6)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func dismiss() {
        // Close the menu bar window so a panel or window can take focus.
        NSApp.keyWindow?.close()
    }
}

/// Liquid Glass behind the whole drop-down, where the system has it.
private struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }
}

// MARK: - Pieces

private struct CompactRow: View {
    @EnvironmentObject private var engine: Engine
    let torrent: TorrentState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            StatusBadge(activity: torrent.activity, side: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(torrent.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(value: torrent.hasMetadata ? torrent.progress : 0,
                            color: torrent.activity.color,
                            height: 5)
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                torrent.paused ? engine.resume(torrent.hash) : engine.pause(torrent.hash)
            } label: {
                Image(systemName: torrent.paused ? "play.circle" : "pause.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(torrent.paused ? Theme.paused : Color.secondary)
            .opacity(hovering ? 1 : 0.55)
            .help(torrent.paused ? "Resume" : "Pause")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            Reveal.inFinder(path: torrent.downloadDir + "/" + torrent.name)
        }
    }

    private var summary: String {
        guard torrent.hasMetadata else { return "Looking for details…" }
        if torrent.paused { return "Paused · \(Format.percent(torrent.progress))" }
        if torrent.complete {
            let shared = torrent.totalUploaded > 0
                ? " · shared \(Format.bytes(torrent.totalUploaded)) · ratio \(Format.ratio(torrent.ratio))"
                : ""
            return "Done\(shared)"
        }
        var text = "\(Format.percent(torrent.progress)) · \(Format.rate(torrent.downloadRate))"
        if let eta = torrent.eta { text += " · \(Format.duration(eta)) left" }
        return text
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary).font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering && enabled ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 5)
    }
}

/// The icon (and live speed) shown in the menu bar itself.
struct MenuBarLabel: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: StatusIcon.template)
            if engine.activeCount > 0, engine.totalDownloadRate > 1024 {
                Text(Format.rate(engine.totalDownloadRate))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
