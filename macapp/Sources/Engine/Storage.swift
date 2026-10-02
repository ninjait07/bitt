import CryptoKit
import Foundation

/// Disk layout: maps the torrent's flat byte stream onto real files.
///
/// Every method here blocks; the session calls them off the main actor.
final class Storage {
    enum StorageError: LocalizedError {
        case escapesDownloadDirectory(String)
        case rangeOutsideTorrent(offset: Int, length: Int)
        case unmappedTail(Int)
        case closed

        var errorDescription: String? {
            switch self {
            case .escapesDownloadDirectory(let path):
                return "file path escapes the download directory: \(path)"
            case .rangeOutsideTorrent(let offset, let length):
                return "range \(offset)+\(length) is outside the torrent"
            case .unmappedTail(let count): return "could not map \(count) trailing bytes"
            case .closed: return "storage is closed"
            }
        }
    }

    /// macOS defaults to a 256 descriptor limit, so keep well clear of it.
    private static let maxOpenFiles = 64

    let meta: Metainfo
    let downloadDirectory: URL
    /// A multi-file torrent gets its own directory; a single-file one does not.
    let root: URL

    private var handles: [String: FileHandle] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private var isClosed = false

    init(meta: Metainfo, downloadDirectory: URL) {
        self.meta = meta
        self.downloadDirectory = downloadDirectory.standardizedFileURL
        self.root = meta.isMultiFile
            ? self.downloadDirectory.appendingPathComponent(meta.name)
            : self.downloadDirectory
    }

    // MARK: - Paths

    func url(for relativePath: String) throws -> URL {
        let full = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard full.path == rootPath || full.path.hasPrefix(rootPath + "/") else {
            throw StorageError.escapesDownloadDirectory(relativePath)
        }
        return full
    }

    /// Create every file at its final size. APFS stores the holes for free.
    func allocate() throws {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        for entry in meta.files {
            let target = try url(for: entry.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            if !manager.fileExists(atPath: target.path) {
                manager.createFile(atPath: target.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: target)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size < UInt64(entry.length) {
                try handle.truncate(atOffset: UInt64(entry.length))
            }
        }
    }

    var existingBytes: Int {
        meta.files.reduce(0) { total, entry in
            guard let target = try? url(for: entry.path),
                  let size = try? FileManager.default
                    .attributesOfItem(atPath: target.path)[.size] as? Int else { return total }
            return total + min(size, entry.length)
        }
    }

    var hasDataOnDisk: Bool { existingBytes > 0 }

    // MARK: - Byte-range mapping

    private struct Segment {
        let path: String
        let inFile: Int
        let inBuffer: Int
        let length: Int
    }

    private func segments(offset: Int, length: Int) throws -> [Segment] {
        guard offset >= 0, length >= 0, offset + length <= meta.totalLength else {
            throw StorageError.rangeOutsideTorrent(offset: offset, length: length)
        }
        var out: [Segment] = []
        var bufferPosition = 0
        var remaining = length
        for entry in meta.files {
            if remaining <= 0 { break }
            guard entry.length > 0 else { continue }
            let fileEnd = entry.offset + entry.length
            let start = offset + bufferPosition
            if start >= fileEnd { continue }
            let inFile = start - entry.offset
            let take = min(entry.length - inFile, remaining)
            out.append(Segment(path: entry.path, inFile: inFile,
                               inBuffer: bufferPosition, length: take))
            bufferPosition += take
            remaining -= take
        }
        guard remaining == 0 else { throw StorageError.unmappedTail(remaining) }
        return out
    }

    private func handle(for relativePath: String) throws -> FileHandle {
        if isClosed { throw StorageError.closed }
        if let existing = handles[relativePath] {
            order.removeAll { $0 == relativePath }
            order.append(relativePath)
            return existing
        }
        let target = try url(for: relativePath)
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if !manager.fileExists(atPath: target.path) {
            manager.createFile(atPath: target.path, contents: nil)
        }
        let opened = try FileHandle(forUpdating: target)
        handles[relativePath] = opened
        order.append(relativePath)
        while order.count > Self.maxOpenFiles {
            let stale = order.removeFirst()
            try? handles.removeValue(forKey: stale)?.close()
        }
        return opened
    }

    // MARK: - I/O

    func write(offset: Int, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        for segment in try segments(offset: offset, length: data.count) {
            let file = try handle(for: segment.path)
            try file.seek(toOffset: UInt64(segment.inFile))
            let start = data.index(data.startIndex, offsetBy: segment.inBuffer)
            let end = data.index(start, offsetBy: segment.length)
            try file.write(contentsOf: data[start..<end])
        }
    }

    func read(offset: Int, length: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data(count: length)
        for segment in try segments(offset: offset, length: length) {
            let file = try handle(for: segment.path)
            try file.seek(toOffset: UInt64(segment.inFile))
            var chunk = try file.read(upToCount: segment.length) ?? Data()
            if chunk.count < segment.length {
                // Short read: the file is smaller than it should be.
                chunk.append(Data(count: segment.length - chunk.count))
            }
            out.replaceSubrange(
                out.index(out.startIndex, offsetBy: segment.inBuffer)
                ..< out.index(out.startIndex, offsetBy: segment.inBuffer + segment.length),
                with: chunk)
        }
        return out
    }

    func writePiece(_ index: Int, data: Data) throws {
        try write(offset: index * meta.pieceLength, data: data)
    }

    func readPiece(_ index: Int) throws -> Data {
        try read(offset: index * meta.pieceLength, length: meta.pieceSize(at: index))
    }

    func readBlock(index: Int, begin: Int, length: Int) throws -> Data {
        try read(offset: index * meta.pieceLength + begin, length: length)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        handles.values.forEach { try? $0.synchronize() }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
        handles.values.forEach { try? $0.close() }
        handles.removeAll()
        order.removeAll()
    }

    // MARK: - Resume

    /// Hash every piece already on disk and return a have-bitfield.
    func verify(progress: ((Int, Int) -> Void)? = nil) -> [Bool] {
        var have = [Bool](repeating: false, count: meta.pieceCount)
        for index in 0..<meta.pieceCount {
            let expected = meta.pieceSize(at: index)
            if let data = try? readPiece(index), data.count == expected {
                have[index] = Data(Insecure.SHA1.hash(data: data)) == meta.pieceHashes[index]
            }
            progress?(index + 1, meta.pieceCount)
        }
        return have
    }
}
