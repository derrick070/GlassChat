import Foundation

/// Disk store for sealed image blobs, separate from the text `MeshStore`.
@MainActor
final class BlobStore {
    static let shared = BlobStore()

    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = base.appendingPathComponent("GlassChatBlobs", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func url(for blobIDHex: String) -> URL {
        rootURL.appendingPathComponent(blobIDHex.lowercased())
    }

    func plaintextURL(for blobIDHex: String) -> URL {
        rootURL.appendingPathComponent("\(blobIDHex.lowercased()).plain")
    }

    func hasCiphertext(_ blobIDHex: String) -> Bool {
        fileManager.fileExists(atPath: url(for: blobIDHex).path)
    }

    func hasPlaintext(_ blobIDHex: String) -> Bool {
        fileManager.fileExists(atPath: plaintextURL(for: blobIDHex).path)
    }

    func putCiphertext(_ data: Data, blobIDHex: String) throws {
        try data.write(to: url(for: blobIDHex), options: .atomic)
        enforceQuota()
    }

    func putPlaintext(_ data: Data, blobIDHex: String) throws {
        try data.write(to: plaintextURL(for: blobIDHex), options: .atomic)
        enforceQuota()
    }

    func ciphertext(for blobIDHex: String) -> Data? {
        try? Data(contentsOf: url(for: blobIDHex))
    }

    func plaintext(for blobIDHex: String) -> Data? {
        try? Data(contentsOf: plaintextURL(for: blobIDHex))
    }

    /// Assemble ciphertext from ordered chunks and persist if hash matches.
    func assemble(
        blobIDHex: String,
        chunks: [Int: Data],
        expectedChunkCount: Int,
        keyData: Data
    ) throws -> Data {
        guard chunks.count == expectedChunkCount else {
            throw StoreError.incomplete
        }
        var ciphertext = Data()
        for index in 0..<expectedChunkCount {
            guard let part = chunks[index] else { throw StoreError.incomplete }
            ciphertext.append(part)
        }
        guard BlobCrypto.verifyBlobID(ciphertext, expectedHex: blobIDHex) else {
            throw StoreError.hashMismatch
        }
        let plaintext = try BlobCrypto.open(ciphertext, keyData: keyData)
        try putCiphertext(ciphertext, blobIDHex: blobIDHex)
        try putPlaintext(plaintext, blobIDHex: blobIDHex)
        return plaintext
    }

    func remove(_ blobIDHex: String) {
        try? fileManager.removeItem(at: url(for: blobIDHex))
        try? fileManager.removeItem(at: plaintextURL(for: blobIDHex))
    }

    enum StoreError: Error {
        case incomplete
        case hashMismatch
    }

    private func enforceQuota() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Pair {
            var blobID: String
            var modified: Date
            var size: Int
        }

        var pairs: [String: Pair] = [:]
        for fileURL in items {
            let name = fileURL.lastPathComponent
            let blobID = name.hasSuffix(".plain") ? String(name.dropLast(6)) : name
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if var existing = pairs[blobID] {
                existing.size += size
                existing.modified = max(existing.modified, modified)
                pairs[blobID] = existing
            } else {
                pairs[blobID] = Pair(blobID: blobID, modified: modified, size: size)
            }
        }

        var ordered = Array(pairs.values)
        var total = ordered.reduce(0) { $0 + $1.size }
        guard total > MediaConstants.blobStoreQuotaBytes else { return }

        ordered.sort { $0.modified < $1.modified }
        while total > MediaConstants.blobStoreQuotaBytes, let oldest = ordered.first {
            remove(oldest.blobID)
            total -= oldest.size
            ordered.removeFirst()
        }
    }
}
