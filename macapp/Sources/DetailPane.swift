import SwiftUI

/// The lower pane: everything known about the selected torrent, in the same
/// visual language as the list above it.
struct DetailPane: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Prefs.showDetailPane) private var showDetailPane = true
    let torrent: TorrentState

    @State private var details: TorrentDetails?
    @State private var tab: Tab = .files
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum Tab: String, CaseIterable, Identifiable {
        case files = "Files"
        case peers = "Peers"
        case trackers = "Trackers"
        case log = "Log"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: refresh)
        .onChange(of: torrent.hash) { _ in
            details = nil
            refresh()
        }
        .onReceive(ticker) { _ in refresh() }
    }

    private func refresh() {
        engine.details(for: torrent.hash) { result in
            if let result { details = result }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                TabChip(title: item.rawValue,
                        isSelected: tab == item,
                        badge: badge(for: item)) {
                    tab = item
                }
            }

            Spacer()

            if let summary = summaryText {
                Text(summary)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button {
                showDetailPane = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide the details pane (⌘I)")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func badge(for item: Tab) -> Int? {
        guard let details else { return nil }
        switch item {
        case .files: return details.files.count
        case .peers: return details.peers.count
        case .trackers: return details.trackers.count
        case .log: return nil
        }
    }

    private var summaryText: String? {
        guard let details else { return nil }
        switch tab {
        case .files:
            guard !details.files.isEmpty else { return nil }
            let noun = details.files.count == 1 ? "file" : "files"
            return "\(details.files.count) \(noun) · \(Format.bytes(details.total))"
        case .peers:
            guard !details.peers.isEmpty else { return nil }
            let active = details.peers.filter { !$0.choked }.count
            return "\(active) of \(details.peers.count) sending"
        case .trackers:
            guard !details.trackers.isEmpty else { return nil }
            let ok = details.trackers.filter { $0.error.isEmpty }.count
            return "\(ok) of \(details.trackers.count) responding"
        case .log:
            guard !details.log.isEmpty else { return nil }
            let noun = details.log.count == 1 ? "entry" : "entries"
            return "\(details.log.count) \(noun)"
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch tab {
        case .files: fileList
        case .peers: peerList
        case .trackers: trackerList
        case .log: logList
        }
    }

    @ViewBuilder private var fileList: some View {
        if let details, !details.files.isEmpty {
            PaneScroll {
                ForEach(details.files) { file in
                    FileRow(file: file)
                }
            }
        } else {
            placeholder("The file list appears once the torrent's details arrive.")
        }
    }

    @ViewBuilder private var peerList: some View {
        if let details, !details.peers.isEmpty {
            PaneScroll {
                ForEach(details.peers) { peer in
                    PeerRow(peer: peer)
                }
            }
        } else {
            placeholder(torrent.paused
                        ? "Paused — BITT is not talking to any peers."
                        : "No peers connected yet.")
        }
    }

    @ViewBuilder private var trackerList: some View {
        if let details, !details.trackers.isEmpty {
            PaneScroll {
                ForEach(details.trackers) { tracker in
                    TrackerRow(tracker: tracker)
                }
            }
        } else {
            placeholder("This torrent has no trackers. Peers can only be found "
                      + "through direct addresses.")
        }
    }

    @ViewBuilder private var logList: some View {
        if let details, !details.log.isEmpty {
            PaneScroll(spacing: 1) {
                ForEach(Array(details.log.enumerated()).reversed(), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
            }
        } else {
            placeholder("Nothing logged yet.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pieces

private struct PaneScroll<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: spacing) {
                content
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
    }
}

private struct TabChip: View {
    let title: String
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).fontWeight(isSelected ? .semibold : .regular)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.18 : 0.10)))
                }
            }
            .font(.callout)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected
                               ? Theme.brandStart.opacity(0.22)
                               : (hovering ? Color.primary.opacity(0.07) : Color.clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FileRow: View {
    let file: TorrentDetails.FileEntry

    private var complete: Bool { file.done >= file.length }
    private var tint: Color { complete ? Theme.seeding : Theme.downloading }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: complete ? "doc.fill" : "doc")
                .foregroundStyle(complete ? Theme.seeding : Color.secondary)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(value: file.fraction, color: tint, height: 4)
            }

            Text(Format.percent(file.fraction))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 52, alignment: .trailing)

            Text(Format.bytes(file.length))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
    }
}

private struct PeerRow: View {
    let peer: TorrentDetails.PeerEntry

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peer.choked ? Color.secondary.opacity(0.5) : Theme.seeding)
                .frame(width: 7, height: 7)

            Text(peer.address)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 168, alignment: .leading)
                .lineLimit(1)

            Text(peer.client)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if peer.rate > 1024 {
                Label(Format.rate(peer.rate), systemImage: "arrow.down")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.downloading)
            }

            Text(Format.bytes(peer.downloaded))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            Image(systemName: peer.incoming ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(peer.incoming ? "They connected to us" : "We connected to them")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
    }
}

private struct TrackerRow: View {
    let tracker: TorrentDetails.TrackerEntry

    private var healthy: Bool { tracker.error.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(healthy ? Theme.seeding : Theme.paused)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.url)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(healthy
                     ? "\(tracker.peers) peers from the last announce"
                     : tracker.error)
                    .font(.caption)
                    .foregroundStyle(healthy ? Color.secondary : Theme.paused)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
    }
}
