import AppKit

/// Everything that points outside the app, in one place.
enum Support {
    /// PromptPay payload in the EMVCo form a Thai bank QR carries, so any Thai
    /// banking app can scan it. Same account as Deft.
    static let promptPayPayload = "00020101021129390016A000000677010111031508898400069126953037645802TH6304C60B"
    static let promptPayName = "นนท์ บรรณวัฒน์"
    static let sponsorsURL = URL(string: "https://github.com/sponsors/ninjait07")!
    static let repositoryURL = URL(string: "https://github.com/ninjait07/bitt")!

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }
}

/// The panel behind the ⓘ button: what this is, and a way to say thanks.
@MainActor
final class AboutWindow: NSObject {
    static let shared = AboutWindow()
    private var window: NSWindow?

    private static let contentWidth: CGFloat = 268

    private override init() { super.init() }

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        build()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Building

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let logo = NSImageView(image: LogoImage.image(side: 128))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 56).isActive = true
        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(12, after: logo)

        let name = label("BITT \(Support.version)", size: 15, weight: .semibold)
        stack.addArrangedSubview(name)

        let what = label("A small BitTorrent client for macOS.\nFree and open source.",
                         size: 11.5, weight: .regular, colour: .secondaryLabelColor)
        stack.addArrangedSubview(what)
        stack.setCustomSpacing(18, after: what)

        let ask = label("If it earns its place, a coffee keeps it going.",
                        size: 12, weight: .medium)
        stack.addArrangedSubview(ask)
        stack.setCustomSpacing(12, after: ask)

        let qr = NSImageView(image: AboutWindow.qrImage(Support.promptPayPayload, side: 180))
        qr.imageScaling = .scaleNone
        qr.wantsLayer = true
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.layer?.cornerRadius = 10
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(qr)
        stack.setCustomSpacing(10, after: qr)

        let payee = label("PromptPay · \(Support.promptPayName)", size: 12, weight: .medium)
        stack.addArrangedSubview(payee)

        let hint = label("Scan with any Thai banking app", size: 10.5, weight: .regular,
                         colour: .tertiaryLabelColor)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(18, after: hint)

        let sponsor = NSButton(title: "", target: self, action: #selector(openSponsors))
        sponsor.bezelStyle = .rounded
        sponsor.bezelColor = NSColor(calibratedRed: 0.75, green: 0.22, blue: 0.54, alpha: 1)
        sponsor.contentTintColor = .white
        sponsor.imagePosition = .imageLeading
        sponsor.imageHugsTitle = true
        sponsor.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        sponsor.attributedTitle = NSAttributedString(string: "  Sponsor on GitHub", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
        ])
        constrain(sponsor, in: stack)

        let source = NSButton(title: "View the source", target: self, action: #selector(openRepository))
        source.bezelStyle = .rounded
        constrain(source, in: stack)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        constrain(close, in: stack)

        let panel = NSWindow(contentRect: .zero,
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "About BITT"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let size = stack.fittingSize
        if #available(macOS 26.0, *) {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = 22
            glass.contentView = stack
            glass.autoresizingMask = [.width, .height]
            panel.contentView = glass
        } else {
            panel.contentView = stack
        }
        panel.setContentSize(size)
        window = panel
    }

    private func constrain(_ button: NSButton, in stack: NSStackView) {
        button.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalToConstant: AboutWindow.contentWidth).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       colour: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.alignment = .center
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: AboutWindow.contentWidth).isActive = true
        return field
    }

    // MARK: - Actions

    @objc private func openSponsors() { NSWorkspace.shared.open(Support.sponsorsURL) }
    @objc private func openRepository() { NSWorkspace.shared.open(Support.repositoryURL) }
    @objc private func closeWindow() { window?.close() }

    /// Build the QR with CoreImage and scale it without blurring.
    static func qrImage(_ payload: String, side: CGFloat) -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        let scale = side / output.extent.width
        let representation = NSCIImageRep(ciImage: output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)))
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
