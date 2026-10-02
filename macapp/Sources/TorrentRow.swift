import SwiftUI

struct TorrentRow: View {
    let torrent: TorrentState
    var isSelected: Bool = false

    private var activity: TorrentState.Activity { torrent.activity }
    private var tint: Color { activity.color }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(activity: activity)

            VStack(alignment: .leading, spacing: 7) {
                titleLine
                ProgressBar(value: torrent.hasMetadata ? torrent.progress : 0, color: tint)
                infoLine
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(isSelected ? tint.opacity(0.14) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.65) : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Lines

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(torrent.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(torrent.hasMetadata ? Format.percent(torrent.progress) : "—")
                .font(.system(.callout, design: .rounded))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private var infoLine: some View {
        HStack(spacing: 7) {
            Text(activity.label)
                .foregroundStyle(tint)
                .fontWeight(.medium)

            if torrent.activity == .checking {
                dot
                Text("this can take a minute on a large torrent")
                    .foregroundStyle(.secondary)
            } else if torrent.hasMetadata {
                dot
                Text("\(Format.bytes(torrent.done)) of \(Format.bytes(torrent.total))")
                    .foregroundStyle(.secondary)

                if torrent.downloadRate > 1024 {
                    dot
                    Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down")
                        .foregroundStyle(Theme.downloading)
                }
                if torrent.uploadRate > 1024 {
                    dot
                    Label(Format.rate(torrent.uploadRate), systemImage: "arrow.up")
                        .foregroundStyle(Theme.seeding)
                }
                if !torrent.paused {
                    dot
                    Text("\(torrent.peers) \(torrent.peers == 1 ? "peer" : "peers")")
                        .foregroundStyle(.secondary)
                }
                if let eta = torrent.eta {
                    dot
                    Text("\(Format.duration(eta)) left").foregroundStyle(.secondary)
                }
                if torrent.totalUploaded > 0 {
                    dot
                    // What a private tracker counts: shared bytes and the ratio.
                    Text("shared \(Format.bytes(torrent.totalUploaded))")
                        .foregroundStyle(.secondary)
                    Text("ratio \(Format.ratio(torrent.ratio))")
                        .foregroundStyle(Theme.seeding)
                        .fontWeight(.medium)
                }
            } else if !torrent.paused {
                dot
                Text("asking peers for this torrent's details")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .labelStyle(.titleAndIcon)
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

// MARK: - Pieces

struct StatusBadge: View {
    let activity: TorrentState.Activity
    var side: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                .fill(activity.color.opacity(0.18))
            Image(systemName: activity.symbol)
                .font(.system(size: side * 0.47, weight: .semibold))
                .foregroundStyle(activity.color)
        }
        .frame(width: side, height: side)
    }
}

/// A plain tinted bar. The stock ProgressView ignores its tint in a few styles,
/// and the colour is the point here.
struct ProgressBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}
