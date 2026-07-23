import Foundation

/// Receiver-pull / Multipeer-push data plane for image blobs.
@MainActor
final class MediaTransferService {
    private let transport: TransportMux
    private let blobStore: BlobStore

    /// blobIDHex → chunkIndex → data
    private var inboundChunks: [String: [Int: Data]] = [:]

    init(transport: TransportMux, blobStore: BlobStore = .shared) {
        self.transport = transport
        self.blobStore = blobStore
    }

    // MARK: - Outbound offer helpers

    func prepareOutboundImage(imageData: Data, preferMultipeerCap: Bool) throws -> (
        prepared: ImageCompressor.Result,
        ciphertext: Data,
        keyData: Data,
        blobIDHex: String,
        chunkCount: Int
    ) {
        let maxBytes = preferMultipeerCap
            ? MediaConstants.multipeerMaxBytes
            : MediaConstants.bleMaxBytes
        let prepared = try ImageCompressor.prepare(imageData: imageData, maxBytes: maxBytes)
        let sealed = try BlobCrypto.seal(prepared.imageData)
        try blobStore.putCiphertext(sealed.ciphertext, blobIDHex: sealed.blobIDHex)
        try blobStore.putPlaintext(prepared.imageData, blobIDHex: sealed.blobIDHex)
        let chunks = BlobCrypto.chunkCount(forByteCount: sealed.ciphertext.count)
        return (prepared, sealed.ciphertext, sealed.keyData, sealed.blobIDHex, chunks)
    }

    /// After an offer is accepted / peer connects, push via Multipeer or wait for pull.
    func pushIfPossible(blobIDHex: String, to peerUUID: UUID) {
        guard blobStore.hasCiphertext(blobIDHex) else { return }
        if transport.hasMultipeerLink(to: peerUUID) {
            let url = blobStore.url(for: blobIDHex)
            let name = MediaConstants.resourceNamePrefix + blobIDHex
            try? transport.sendResource(at: url, withName: name, to: peerUUID)
        }
    }

    // MARK: - Inbound control

    func startFetch(blobIDHex: String, chunkCount: Int, from peerUUID: UUID, keyData: Data) {
        if blobStore.hasPlaintext(blobIDHex) || blobStore.hasCiphertext(blobIDHex) {
            if let ciphertext = blobStore.ciphertext(for: blobIDHex),
               BlobCrypto.verifyBlobID(ciphertext, expectedHex: blobIDHex),
               let _ = try? BlobCrypto.open(ciphertext, keyData: keyData) {
                if !blobStore.hasPlaintext(blobIDHex),
                   let plain = try? BlobCrypto.open(ciphertext, keyData: keyData) {
                    try? blobStore.putPlaintext(plain, blobIDHex: blobIDHex)
                }
                return
            }
        }

        // Prefer Multipeer resource push — ask sender by requesting all chunks;
        // sender will short-circuit to sendResource when MC is available.
        let missing = Array(0..<chunkCount)
        requestChunks(blobIDHex: blobIDHex, missing: missing, from: peerUUID)
    }

    func handleBlobRequest(_ frame: WireFrame, from peerUUID: UUID) {
        guard let blobIDHex = frame.blobIDHex,
              let missing = frame.missingChunkIndexes,
              let ciphertext = blobStore.ciphertext(for: blobIDHex) else { return }

        if transport.hasMultipeerLink(to: peerUUID) {
            pushIfPossible(blobIDHex: blobIDHex, to: peerUUID)
            return
        }

        guard transport.hasDirectLink(to: peerUUID) else { return }

        let total = BlobCrypto.chunkCount(forByteCount: ciphertext.count)
        for index in missing.sorted() {
            guard let part = BlobCrypto.chunk(of: ciphertext, index: index) else { continue }
            let chunkFrame = WireFrame.blobChunk(
                senderUUID: transport.peerUUID,
                blobIDHex: blobIDHex,
                chunkIndex: index,
                chunkCount: total,
                chunkData: part
            )
            try? transport.sendDirect(chunkFrame, to: peerUUID)
        }
    }

    /// Returns plaintext when assembly completes; nil if still incomplete.
    func handleBlobChunk(
        _ frame: WireFrame,
        keyData: Data,
        expectedChunkCount: Int
    ) -> Data? {
        guard let blobIDHex = frame.blobIDHex,
              let index = frame.chunkIndex,
              let data = frame.chunkData else { return nil }

        var map = inboundChunks[blobIDHex] ?? [:]
        map[index] = data
        inboundChunks[blobIDHex] = map

        guard map.count >= expectedChunkCount else { return nil }

        do {
            let plaintext = try blobStore.assemble(
                blobIDHex: blobIDHex,
                chunks: map,
                expectedChunkCount: expectedChunkCount,
                keyData: keyData
            )
            inboundChunks.removeValue(forKey: blobIDHex)
            return plaintext
        } catch {
            return nil
        }
    }

    func handleResource(name: String, localURL: URL, keyData: Data, expectedBlobID: String) -> Data? {
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard name.hasPrefix(MediaConstants.resourceNamePrefix) else { return nil }
        let blobIDHex = String(name.dropFirst(MediaConstants.resourceNamePrefix.count)).lowercased()
        guard blobIDHex == expectedBlobID.lowercased() else { return nil }
        guard let ciphertext = try? Data(contentsOf: localURL) else { return nil }
        guard BlobCrypto.verifyBlobID(ciphertext, expectedHex: blobIDHex) else { return nil }
        guard let plaintext = try? BlobCrypto.open(ciphertext, keyData: keyData) else { return nil }
        try? blobStore.putCiphertext(ciphertext, blobIDHex: blobIDHex)
        try? blobStore.putPlaintext(plaintext, blobIDHex: blobIDHex)
        inboundChunks.removeValue(forKey: blobIDHex)
        return plaintext
    }

    func missingChunks(for blobIDHex: String, chunkCount: Int) -> [Int] {
        let have = inboundChunks[blobIDHex] ?? [:]
        return (0..<chunkCount).filter { have[$0] == nil }
    }

    func requestChunks(blobIDHex: String, missing: [Int], from peerUUID: UUID) {
        guard !missing.isEmpty else { return }
        // Batch to keep frames small.
        let batchSize = 32
        var start = 0
        while start < missing.count {
            let end = min(start + batchSize, missing.count)
            let batch = Array(missing[start..<end])
            let frame = WireFrame.blobRequest(
                senderUUID: transport.peerUUID,
                blobIDHex: blobIDHex,
                missingChunkIndexes: batch
            )
            try? transport.sendDirect(frame, to: peerUUID)
            start = end
        }
    }

    func progress(for blobIDHex: String, chunkCount: Int) -> Double {
        guard chunkCount > 0 else { return 0 }
        if blobStore.hasPlaintext(blobIDHex) { return 1 }
        let have = inboundChunks[blobIDHex]?.count ?? 0
        return Double(have) / Double(chunkCount)
    }
}
