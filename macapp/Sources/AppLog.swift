import Foundation

/// A small always-on log, so a problem in the shipped app can be diagnosed
/// without a debugger. Lives next to the engine's state file.
enum AppLog {
    private static let queue = DispatchQueue(label: "com.nonbannawat.bitt.log")

    private static let fileURL: URL = {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BITT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("app.log")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed format: a log should not follow the user's calendar or locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
            trimIfHuge()
        }
    }

    private static func trimIfHuge() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 512 * 1024 else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").suffix(500).joined(separator: "\n")
        try? (kept + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
