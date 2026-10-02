import AppKit

/// The panel that comes up when a torrent arrives from Finder, a browser or a
/// drop: what it is, where it will go, and whether to start now.
///
/// Built by hand rather than with NSAlert, which fixes its own margins and puts
/// the icon off to one side. Here the panel is only as wide as its buttons.
@MainActor
final class AddTorrentPrompt: NSObject {
    enum Decision {
        case start(directory: String)
        case paused(directory: String)
        case cancel
    }

    private static let contentWidth: CGFloat = 248
    private static let sideMargin: CGFloat = 18

    private var directory: String
    private var decision: Decision = .cancel
    private let pathLabel = NSTextField(labelWithString: "")
    private var window: NSWindow?

    private init(directory: String) {
        self.directory = directory
        super.init()
    }

    /// Brings BITT forward and asks. Returns what the user chose.
    static func run(preview: TorrentPreview?, source: String,
                    defaultDirectory: String) -> Decision {
        NSApp.activate(ignoringOtherApps: true)

        if let preview, preview.alreadyAdded {
            let alert = NSAlert()
            alert.messageText = "“\(preview.name)” is already in the list"
            alert.informativeText = "BITT is already looking after this torrent."
            alert.icon = LogoImage.image(side: 128)
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .cancel
        }

        return AddTorrentPrompt(directory: defaultDirectory)
            .show(preview: preview, source: source)
    }

    // MARK: - Building

    private func show(preview: TorrentPreview?, source: String) -> Decision {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 20, left: Self.sideMargin,
                                        bottom: 16, right: Self.sideMargin)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView(image: LogoImage.image(side: 128))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 60).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 60).isActive = true
        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(12, after: logo)

        let title = centeredLabel(displayName(preview: preview, source: source),
                                  font: .systemFont(ofSize: 13, weight: .semibold))
        stack.addArrangedSubview(title)

        let subtitle = centeredLabel(self.subtitle(for: preview),
                                     font: .systemFont(ofSize: 11),
                                     colour: .secondaryLabelColor)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)

        if let warning = self.warning(for: preview) {
            let label = centeredLabel(warning, font: .systemFont(ofSize: 11),
                                      colour: .systemOrange)
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(16, after: label)
        }

        for view in savePathViews() { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        let download = button("Download Now", action: #selector(chooseDownload))
        download.keyEquivalent = "\r"
        download.bezelColor = .controlAccentColor
        stack.addArrangedSubview(download)

        let paused = button("Add Paused", action: #selector(choosePaused))
        paused.keyEquivalent = "p"
        paused.keyEquivalentModifierMask = [.command]
        stack.addArrangedSubview(paused)

        let cancel = button("Cancel", action: #selector(chooseCancel))
        cancel.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(cancel)

        let panel = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        let size = stack.fittingSize
        if #available(macOS 26.0, *) {
            // Liquid Glass: the window itself is clear and the glass view draws
            // the surface, so what is behind shows through and refracts.
            panel.isOpaque = false
            panel.backgroundColor = .clear

            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = 22
            glass.contentView = stack
            glass.autoresizingMask = [.width, .height]
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            panel.contentView = glass
        } else {
            panel.contentView = stack
        }
        panel.setContentSize(size)
        panel.center()
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        window = nil
        return decision
    }

    private func centeredLabel(_ text: String, font: NSFont,
                               colour: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = colour
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return control
    }

    // MARK: - Save location

    private func savePathViews() -> [NSView] {
        let caption = centeredLabel("SAVING TO",
                                    font: .systemFont(ofSize: 9, weight: .semibold),
                                    colour: .tertiaryLabelColor)

        pathLabel.stringValue = shortened(directory)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .labelColor
        pathLabel.alignment = .center
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.toolTip = directory
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let change = NSButton(title: "Change…", target: self, action: #selector(chooseFolder))
        change.bezelStyle = .rounded
        change.controlSize = .small
        change.font = .systemFont(ofSize: 11)
        change.translatesAutoresizingMaskIntoConstraints = false

        return [caption, pathLabel, change]
    }

    @objc private func chooseFolder() {
        guard let folder = AddFlow.chooseFolder(title: "Choose where this download goes",
                                                startingAt: directory,
                                                prompt: "Save Here") else { return }
        directory = folder
        pathLabel.stringValue = shortened(folder)
        pathLabel.toolTip = folder
    }

    // MARK: - Choices

    @objc private func chooseDownload() { finish(.start(directory: directory)) }
    @objc private func choosePaused() { finish(.paused(directory: directory)) }
    @objc private func chooseCancel() { finish(.cancel) }

    private func finish(_ value: Decision) {
        decision = value
        NSApp.stopModal()
    }

    // MARK: - Text

    private func displayName(preview: TorrentPreview?, source: String) -> String {
        let name: String
        if let preview, !preview.name.isEmpty {
            name = preview.name
        } else if source.lowercased().hasPrefix("magnet:") {
            name = "this magnet link"
        } else {
            name = (source as NSString).lastPathComponent
        }
        return "Add “\(name)”?"
    }

    /// BITT has no DHT, so a link with no trackers and no peer hints has
    /// nowhere to look. Better to say it now than to let it sit at 0%.
    private func warning(for preview: TorrentPreview?) -> String? {
        guard let preview, preview.trackerCount == 0 else { return nil }
        return preview.isMagnet
            ? "⚠︎ This magnet has no trackers. BITT has no DHT, so there is "
            + "nowhere to look for peers and it will not start."
            : "⚠︎ This torrent lists no trackers. Peers can only be found "
            + "through direct addresses."
    }

    private func subtitle(for preview: TorrentPreview?) -> String {
        guard let preview else { return "BITT could not read this torrent yet." }
        if preview.isMagnet {
            return "Magnet link — its size and contents arrive from the peers."
        }
        let files = preview.fileCount == 1 ? "1 file" : "\(preview.fileCount) files"
        return "\(Format.bytes(Int64(preview.totalLength))) · \(files)"
    }

    private func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
