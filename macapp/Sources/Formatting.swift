import AppKit
import Foundation
import UserNotifications

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, count))
    }

    static func bytes(_ count: Double) -> String {
        bytes(Int64(max(0, count)))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "—" : bytes(bytesPerSecond) + "/s"
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86_400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86_400)d \((total % 86_400) / 3600)h"
    }

    static func ratio(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }
}

enum Notifier {
    private static var authorised = false

    /// Asks once; if the app is unsigned the request simply fails and we carry on.
    static func prepare() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorised = granted
            }
    }

    static func finished(name: String, path: String) {
        NSSound(named: "Glass")?.play()

        guard authorised else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download finished"
        content.body = name
        content.sound = .default
        if !path.isEmpty { content.userInfo = ["path": path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum Reveal {
    static func inFinder(path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func open(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
