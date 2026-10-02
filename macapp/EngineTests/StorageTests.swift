import Foundation

enum StorageTests {
    static func run(fixtures: URL?) {
        Check.section("Storage")

        guard let fixtures,
              let meta = try? Metainfo.parse(
                contentsOf: fixtures.appendingPathComponent("sample.torrent")) else {
            print("  (skipped: no fixtures)")
            return
        }

        // Rebuild the exact byte stream the fixture payload represents.
        let payloadRoot = fixtures.appendingPathComponent("payload")
        var stream = Data()
        for entry in meta.files {
            guard let part = try? Data(contentsOf: payloadRoot
                                        .appendingPathComponent(entry.path)) else {
                Check.that("fixture payload is readable") { false }
                return
            }
            stream.append(part)
        }
        Check.equal("payload stream length", stream.count, meta.totalLength)

        let out = fixtures.appendingPathComponent("storage-out")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let storage = Storage(meta: meta, downloadDirectory: out)

        Check.that("allocates every file at its final size") {
            try storage.allocate()
            return meta.files.allSatisfy { entry in
                let path = try! storage.url(for: entry.path).path
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                return size == entry.length
            }
        }

        Check.that("writes and reads back across file boundaries") {
            for index in 0..<meta.pieceCount {
                let start = index * meta.pieceLength
                let piece = stream[start..<(start + meta.pieceSize(at: index))]
                try storage.writePiece(index, data: Data(piece))
            }
            return try storage.read(offset: 0, length: meta.totalLength) == stream
        }

        Check.that("reads a block from the middle of a piece") {
            let block = try storage.readBlock(index: 1, begin: 100, length: 50)
            let start = meta.pieceLength + 100
            return block == Data(stream[start..<(start + 50)])
        }

        Check.that("verify finds every piece") {
            storage.verify().allSatisfy { $0 }
        }

        Check.that("files on disk match the originals byte for byte") {
            meta.files.allSatisfy { entry in
                let written = try? Data(contentsOf: storage.url(for: entry.path))
                let original = try? Data(contentsOf: payloadRoot.appendingPathComponent(entry.path))
                return written != nil && written == original
            }
        }

        Check.that("allocate makes an empty folder look full of data") {
            // This is why "is there anything on disk?" has to be asked before
            // allocate(): afterwards every file exists at its final size, so a
            // brand new torrent would be hash-checked from end to end, and the
            // piece manager would not exist while peers were already arriving.
            let fresh = fixtures.appendingPathComponent("storage-trap")
            try? FileManager.default.removeItem(at: fresh)
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let store = Storage(meta: meta, downloadDirectory: fresh)
            defer { store.close() }
            let before = store.hasDataOnDisk
            try store.allocate()
            return before == false && store.hasDataOnDisk == true
        }

        Check.throwsError("refuses a range outside the torrent") {
            try storage.read(offset: meta.totalLength, length: 10)
        }

        Check.that("verify reports nothing on an empty directory") {
            let empty = fixtures.appendingPathComponent("storage-empty")
            try? FileManager.default.removeItem(at: empty)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let blank = Storage(meta: meta, downloadDirectory: empty)
            try blank.allocate()
            defer { blank.close() }
            return !blank.verify().contains(true)
        }

        storage.close()
    }
}
