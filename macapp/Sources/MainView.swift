import SwiftUI
import UniformTypeIdentifiers

enum Filter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case finished = "Finished"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .downloading: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.circle.fill"
        }
    }

    func matches(_ torrent: TorrentState) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return torrent.activity == .downloading || torrent.activity == .metadata
        case .seeding: return torrent.activity == .seeding
        // A finished torrent that is paused is still paused: say so, even
        // though it also counts as Finished.
        case .paused: return torrent.paused
        case .finished: return torrent.complete
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Prefs.showDetailPane) private var showInspector = false
    @AppStorage(Prefs.askWhereToSave) private var askWhereToSave = false

    @State private var filter: Filter = .all
    @State private var selection: String?
    @State private var showMagnetSheet = false
    @State private var magnetText = ""
    @State private var showFileImporter = false
    @State private var removalTarget: TorrentState?
    @State private var dropTargeted = false
    @FocusState private var listFocused: Bool

    static let torrentType = UTType(filenameExtension: "torrent") ?? .data

    private var visible: [TorrentState] { engine.torrents.filter { filter.matches($0) } }
    private var selected: TorrentState? { engine.torrent(selection) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 860, minHeight: 500)
        .sheet(isPresented: $showMagnetSheet) { magnetSheet }
        .sheet(item: $removalTarget) { target in
            RemoveSheet(torrent: target) { deleteFiles in
                engine.remove(target.hash, deleteData: deleteFiles)
                if selection == target.hash { selection = nil }
                removalTarget = nil
            } cancel: {
                removalTarget = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [Self.torrentType],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                AddFlow.addMany(urls.map(\.path))
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .onChange(of: engine.torrents) { torrents in
            if selection == nil || !torrents.contains(where: { $0.hash == selection }) {
                selection = visible.first?.hash
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bittOpenFileRequested)) { _ in
            showFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .bittAddMagnetRequested)) { _ in
            magnetText = ""
            showMagnetSheet = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(Filter.allCases, selection: $filter) { item in
            filterRow(item).tag(item)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 186, ideal: 200, max: 260)
        .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { rateSummary }
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("BITT").font(.headline)
                Text("BitTorrent").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func filterRow(_ item: Filter) -> some View {
        let count = engine.torrents.filter(item.matches).count
        return HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .foregroundStyle(item.color ?? Color.secondary)
                .frame(width: 17)
            Text(item.rawValue)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Color.primary.opacity(0.75) : Color.secondary)
        }
    }

    private var rateSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            rateLine(symbol: "arrow.down", value: engine.totalDownloadRate,
                     color: Theme.downloading, limit: engine.settings.downloadLimit)
            rateLine(symbol: "arrow.up", value: engine.totalUploadRate,
                     color: Theme.seeding, limit: engine.settings.uploadLimit)
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isConnectable ? Theme.seeding : Theme.paused)
                    .frame(width: 6, height: 6)
                Text(connectabilityText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .help(engine.isConnectable
                  ? "Other peers can reach you, which keeps your ratio healthy."
                  : "No peer has connected to you yet, so you can download but "
                  + "barely upload.\n\nRouter: \(engine.portMapping)")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectabilityText: String {
        guard engine.listenPort > 0 else { return "No incoming port" }
        return engine.isConnectable
            ? "Port \(engine.listenPort) · reachable"
            : "Port \(engine.listenPort) · not reached yet"
    }

    private func rateLine(symbol: String, value: Double, color: Color,
                          limit: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(value > 1024 ? color : Color.secondary)
            Text(Format.rate(value))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(value > 1024 ? Color.primary : Color.secondary)
            if limit > 0 {
                Image(systemName: "speedometer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Limited to \(Format.rate(Double(limit)))")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch engine.status {
        case .failed(let message):
            EngineProblemView(message: message) { engine.start() }
        case .starting:
            VStack(spacing: 14) {
                BrandMark(size: 52)
                ProgressView().controlSize(.small)
                Text("Starting the torrent engine…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            transfers.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    downloadFolderBar
                }
            }
        }
    }

    @ViewBuilder private var transfers: some View {
        if engine.torrents.isEmpty {
            EmptyStateView(addFile: { showFileImporter = true },
                           addMagnet: { magnetText = ""; showMagnetSheet = true })
                .overlay(dropHighlight)
        } else {
            VSplitView {
                transferList
                if showInspector, let selected {
                    DetailPane(torrent: selected)
                        .frame(minHeight: 170, idealHeight: 250)
                }
            }
        }
    }

    /// Laid out by hand rather than with `List(selection:)`: the system
    /// selection highlight paints the whole row blue, which would bury the very
    /// status colours this list is built around.
    private var transferList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { torrent in
                        TorrentRow(torrent: torrent, isSelected: selection == torrent.hash)
                            .id(torrent.hash)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = torrent.hash
                                listFocused = true   // so the arrow keys work straight away
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                Reveal.inFinder(path: torrent.downloadDir + "/" + torrent.name)
                            })
                            .contextMenu {
                                contextMenu(for: torrent)
                            }
                    }
                }
                .padding(10)
            }
            .focusable()
            .focused($listFocused)
            .modifier(NoFocusRing())
            .onAppear { listFocused = true }
            .onMoveCommand { direction in
                moveSelection(direction, scrollingWith: proxy)
            }
        }
        .frame(minHeight: 190)
        .overlay(dropHighlight)
    }

    /// Arrow keys walk the list, the way the stock one would.
    private func moveSelection(_ direction: MoveCommandDirection, scrollingWith proxy: ScrollViewProxy) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.hash == selection }
        let next: Int
        switch direction {
        case .down: next = min((current ?? -1) + 1, rows.count - 1)
        case .up: next = max((current ?? rows.count) - 1, 0)
        default: return
        }
        selection = rows[next].hash
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rows[next].hash) }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.brandStart, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Download folder

    private var downloadFolderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.brandStart)

            VStack(alignment: .leading, spacing: 1) {
                Text("SAVING TO")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(displayDownloadPath)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(engine.settings.downloadDir)
            }

            Spacer(minLength: 12)

            Toggle("Ask each time", isOn: $askWhereToSave)
                .toggleStyle(.checkbox)
                .help("Choose a folder every time a torrent is added")

            Button("Change…", action: changeDownloadFolder)
                .help("Pick a different download folder")

            Button {
                Reveal.open(path: engine.settings.downloadDir)
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .help("Open the download folder in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBar()
    }

    private var displayDownloadPath: String {
        let home = NSHomeDirectory()
        let path = engine.settings.downloadDir
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func changeDownloadFolder() {
        guard let folder = AddFlow.chooseFolder(title: "Choose where downloads are saved",
                                                startingAt: engine.settings.downloadDir,
                                                prompt: "Use This Folder") else { return }
        var updated = engine.settings
        updated.downloadDir = folder
        engine.apply(settings: updated)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // A flexible space first: with the window title hidden there is
            // nothing else holding the buttons over to the trailing edge.
            Spacer()

            // Borderless and small: the icon is the control, with no capsule
            // around it, so the toolbar stays out of the way of the list.
            // One add button: clicking it opens a file, holding it offers both.
            Menu {
                Button("Torrent File…") { showFileImporter = true }
                Button("Magnet Link…") { magnetText = ""; showMagnetSheet = true }
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                showFileImporter = true
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Add a torrent (⌘O) — hold for magnet links")

            Button {
                guard let selected else { return }
                selected.paused ? engine.resume(selected.hash) : engine.pause(selected.hash)
            } label: {
                Label(selected?.paused == true ? "Resume" : "Pause",
                      systemImage: selected?.paused == true ? "play.fill" : "pause.fill")
            }
            .disabled(selected == nil)
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(selected?.paused == true ? "Resume this torrent" : "Pause this torrent")

            Button { removalTarget = selected } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selected == nil)
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Remove this torrent")

            Button { showInspector.toggle() } label: {
                Label("Details", systemImage: showInspector
                      ? "square.bottomhalf.filled" : "square.bottomthird.inset.filled")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(showInspector ? "Hide the details pane (⌘I)" : "Show files, peers and trackers (⌘I)")
        }
    }

    @ViewBuilder private func contextMenu(for torrent: TorrentState) -> some View {
        Button(torrent.paused ? "Resume" : "Pause") {
            torrent.paused ? engine.resume(torrent.hash) : engine.pause(torrent.hash)
        }
        Button("Show in Finder") {
            Reveal.inFinder(path: torrent.downloadDir + "/" + torrent.name)
        }
        Divider()
        Button("Copy Magnet Link") {
            let magnet = "magnet:?xt=urn:btih:\(torrent.hash)&dn="
                + (torrent.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(magnet, forType: .string)
        }
        Divider()
        Button("Remove…", role: .destructive) { removalTarget = torrent }
    }

    // MARK: - Magnet sheet

    private var magnetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Add a magnet link").font(.headline)
            }
            Text("Paste a link that starts with magnet:?xt=urn:btih:")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $magnetText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 520, height: 92)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            HStack {
                Button("Paste from Clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        magnetText = text
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { showMagnetSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let trimmed = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { AddFlow.add(trimmed) }
                    showMagnetSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!magnetText.lowercased().contains("magnet:"))
            }
        }
        .padding(20)
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "torrent" else { return }
                    Task { @MainActor in AddFlow.add(url.path) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String,
                          text.lowercased().hasPrefix("magnet:") else { return }
                    Task { @MainActor in AddFlow.add(text) }
                }
            }
        }
        return handled
    }
}

// MARK: - Supporting views

struct RemoveSheet: View {
    let torrent: TorrentState
    let confirm: (Bool) -> Void
    let cancel: () -> Void

    @State private var deleteFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusBadge(activity: torrent.activity, side: 28)
                Text("Remove “\(torrent.name)”?").font(.headline).lineLimit(2)
            }
            Text("It will be taken out of the list and the engine will stop talking to its peers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete the downloaded files", isOn: $deleteFiles)
            if deleteFiles {
                Label("The files are deleted straight away, not moved to the Trash.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { confirm(deleteFiles) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct EmptyStateView: View {
    let addFile: () -> Void
    let addMagnet: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            BrandMark(size: 76)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            VStack(spacing: 6) {
                Text("No torrents yet").font(.title2).fontWeight(.medium)
                Text("Drag a .torrent file here, paste a magnet link,\nor use the buttons below.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Add Torrent File…", action: addFile)
                Button("Add Magnet Link…", action: addMagnet)
            }
            .controlSize(.large)
            .modifier(GlassButtons())
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The system glass button style where it exists.
struct GlassButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
        }
    }
}

struct EngineProblemView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.paused)
            Text("The torrent engine could not start").font(.title3).fontWeight(.medium)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            Button("Try Again", action: retry).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list has to be focusable to receive arrow keys, but the focus ring
/// around the whole scroll area is just noise.
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

extension Notification.Name {
    static let bittOpenFileRequested = Notification.Name("BittOpenFileRequested")
    static let bittAddMagnetRequested = Notification.Name("BittAddMagnetRequested")
}
