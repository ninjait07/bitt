import SwiftUI

/// One place for the status colours, so the sidebar, the rows, the menu bar
/// panel and the progress bars can never disagree about what blue means.
enum Theme {
    /// Pulling data down.
    static let downloading = Color(red: 0.25, green: 0.55, blue: 1.00)
    /// Sharing data back out.
    static let seeding = Color(red: 0.18, green: 0.78, blue: 0.44)
    /// Stopped by the user.
    static let paused = Color(red: 0.98, green: 0.68, blue: 0.18)
    /// Complete and no longer sharing.
    static let finished = Color(red: 0.16, green: 0.72, blue: 0.64)
    /// Still working out what the torrent contains.
    static let metadata = Color(red: 0.64, green: 0.42, blue: 0.98)

    /// The logo gradient, reused for accents.
    static let brandStart = Color(red: 0.33, green: 0.42, blue: 0.98)
    static let brandEnd = Color(red: 0.52, green: 0.22, blue: 0.85)

    static let rowCorner: CGFloat = 8
}

/// Liquid Glass where the system has it, and the previous materials where it
/// does not. The app still runs on macOS 13, so every use has to degrade.
struct GlassBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            content.background(.bar)
        }
    }
}

struct GlassCard: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint).interactive(),
                                    in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint?.opacity(0.18) ?? Color.primary.opacity(0.06))
            )
        }
    }
}

extension View {
    func glassBar() -> some View { modifier(GlassBar()) }

    func glassCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint))
    }
}

extension TorrentState.Activity {
    var color: Color {
        switch self {
        case .downloading: return Theme.downloading
        case .seeding: return Theme.seeding
        case .paused: return Theme.paused
        case .finished: return Theme.finished
        case .metadata: return Theme.metadata
        }
    }
}

extension Filter {
    /// The colour of the status this filter selects; `All` stays neutral.
    var color: Color? {
        switch self {
        case .all: return nil
        case .downloading: return Theme.downloading
        case .seeding: return Theme.seeding
        case .paused: return Theme.paused
        case .finished: return Theme.finished
        }
    }
}
