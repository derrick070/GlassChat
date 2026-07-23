import Foundation

/// Receiver-pull / Multipeer-push data plane for image blobs.
@MainActor
final class MediaTransferService {
    private let transport: TransportMux
    private let blobStore: BlobStore

    /// blobIDHex → chunkIndex → data
    private var inboundChunks: [String: [Int: Data]] = [:]
    /// Dedupes Multipeer resource pushes within a session: "peer|blobID".
    private var pushedResources: Set<String> = []
    /// Active fetch retry deadlines.
    private var fetchAttempts: [String: Int] = [:]
    private var fetchRetryTasks: [String: Task<Void, Never>] = [:]

    static let maxFetchAttempts = 8
    static let fetchRetryDelay: Duration = .seconds(3)
    static let maxChunkCount = 512
    static let maxThumbnailBytes = MediaConstants.thumbnailMaxBytes * 2
    static let maxCiphertextBytes = MediaConstants.multipeerMaxBytes + 64

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

    static func isValidOffer(
        blobKeyData: Data,
        byteCount: Int,
        chunkCount: Int,
        thumbnailData: Data
    ) -> Bool {
        guard blobKeyData.count == 32 else { return false }
        guard chunkCount > 0, chunkCount <= maxChunkCount else { return false }
        guard byteCount > 0, byteCount <= maxCiphertextBytes else { return false }
        guard thumbnailData.count <= maxThumbnailBytes else { return false }
        let expectedChunks = BlobCrypto.chunkCount(forByteCount: byteCount)
        return abs(expectedChunks - chunkCount) <= 1
    }

    /// Invoked on the main actor when a fetch succeeds or permanently fails.
    var onFetchTerminal: ((String, MediaTransferStatus) -> Void)?

    /// After an offer is accepted / peer connects, push via Multipeer at most once per peer/blob.
    @discardableResult
    func pushIfPossible(blobIDHex: String, to peerUUID: UUID) -> Bool {
        guard blobStore.hasCiphertext(blobIDHex) else { return false }
        guard transport.hasMultipeerLink(to: peerUUID) else { return false }
        let key = pushKey(peerUUID: peerUUID, blobIDHex: blobIDHex)
        guard !pushedResources.contains(key) else { return false }
        pushedResources.insert(key)
        let url = blobStore.url(for: blobIDHex)
        let name = MediaConstants.resourceNamePrefix + blobIDHex
        do {
            try transport.sendResource(at: url, withName: name, to: peerUUID)
            return true
        } catch {
            pushedResources.remove(key)
            return false
        }
    }

    func clearPushDedupe(for peerUUID: UUID) {
        let prefix = peerUUID.uuidString + "|"
        pushedResources = pushedResources.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: - Inbound control

    /// Start or resume a fetch. Returns false if no direct path is available yet.
    @discardableResult
    func startFetch(
        blobIDHex: String,
        chunkCount: Int,
        from peerUUID: UUID,
        keyData: Data
    ) -> Bool {
        if blobStore.hasPlaintext(blobIDHex) {
            completeFetch(blobIDHex: blobIDHex)
            return true
        }
        if let ciphertext = blobStore.ciphertext(for: blobIDHex),
           BlobCrypto.verifyBlobID(ciphertext, expectedHex: blobIDHex),
           let plain = try? BlobCrypto.open(ciphertext, keyData: keyData) {
            try? blobStore.putPlaintext(plain, blobIDHex: blobIDHex)
            completeFetch(blobIDHex: blobIDHex)
            return true
        }

        guard transport.hasDirectLink(to: peerUUID) else {
            return false
        }

        // Multipeer: one request is enough — sender short-circuits to sendResource.
        if transport.hasMultipeerLink(to: peerUUID) {
            let frame = WireFrame.blobRequest(
                senderUUID: transport.peerUUID,
                blobIDHex: blobIDHex,
                missingChunkIndexes: []
            )
            try? transport.sendDirect(frame, to: peerUUID)
            scheduleRetry(
                blobIDHex: blobIDHex,
                chunkCount: chunkCount,
                from: peerUUID,
                keyData: keyData
            )
            return true
        }

        let missing = missingChunks(for: blobIDHex, chunkCount: chunkCount)
        requestChunks(blobIDHex: blobIDHex, missing: missing, from: peerUUID)
        scheduleRetry(
            blobIDHex: blobIDHex,
            chunkCount: chunkCount,
            from: peerUUID,
            keyData: keyData
        )
        return true
    }

    func handleBlobRequest(
        _ frame: WireFrame,
        from peerUUID: UUID,
        allowedBlobIDs: Set<String>
    ) {
        guard let blobIDHex = frame.blobIDHex?.lowercased() else { return }
        guard allowedBlobIDs.contains(blobIDHex) else { return }
        guard let ciphertext = blobStore.ciphertext(for: blobIDHex) else { return }

        if transport.hasMultipeerLink(to: peerUUID) {
            pushIfPossible(blobIDHex: blobIDHex, to: peerUUID)
            return
        }

        guard transport.hasDirectLink(to: peerUUID) else { return }

        let total = BlobCrypto.chunkCount(forByteCount: ciphertext.count)
        let missing: [Int]
        if let requested = frame.missingChunkIndexes, !requested.isEmpty {
            missing = requested
        } else {
            // Empty list = "send everything" (Multipeer short-circuit miss / full pull).
            missing = Array(0..<total)
        }

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
    /// Throws through optional: clears poisoned state on hash failure.
    func handleBlobChunk(
        _ frame: WireFrame,
        from peerUUID: UUID,
        expectedSender: UUID,
        keyData: Data,
        expectedChunkCount: Int
    ) -> Data? {
        guard peerUUID == expectedSender else { return nil }
        guard let blobIDHex = frame.blobIDHex?.lowercased(),
              let index = frame.chunkIndex,
              let data = frame.chunkData else { return nil }
        guard index >= 0, index < expectedChunkCount else { return nil }

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
            completeFetch(blobIDHex: blobIDHex)
            return plaintext
        } catch {
            // Drop poisoned partials so a retry can start clean.
            inboundChunks.removeValue(forKey: blobIDHex)
            return nil
        }
    }

    func handleResource(
        name: String,
        localURL: URL,
        from peerUUID: UUID,
        expectedSender: UUID,
        keyData: Data,
        expectedBlobID: String
    ) -> Data? {
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard peerUUID == expectedSender else { return nil }
        guard name.hasPrefix(MediaConstants.resourceNamePrefix) else { return nil }
        let blobIDHex = String(name.dropFirst(MediaConstants.resourceNamePrefix.count)).lowercased()
        guard blobIDHex == expectedBlobID.lowercased() else { return nil }
        guard let ciphertext = try? Data(contentsOf: localURL) else { return nil }
        guard BlobCrypto.verifyBlobID(ciphertext, expectedHex: blobIDHex) else { return nil }
        guard let plaintext = try? BlobCrypto.open(ciphertext, keyData: keyData) else { return nil }
        try? blobStore.putCiphertext(ciphertext, blobIDHex: blobIDHex)
        try? blobStore.putPlaintext(plaintext, blobIDHex: blobIDHex)
        completeFetch(blobIDHex: blobIDHex)
        return plaintext
    }

    func missingChunks(for blobIDHex: String, chunkCount: Int) -> [Int] {
        let have = inboundChunks[blobIDHex] ?? [:]
        return (0..<chunkCount).filter { have[$0] == nil }
    }

    func requestChunks(blobIDHex: String, missing: [Int], from peerUUID: UUID) {
        guard !missing.isEmpty else { return }
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

    func cancelFetch(blobIDHex: String) {
        fetchRetryTasks[blobIDHex]?.cancel()
        fetchRetryTasks.removeValue(forKey: blobIDHex)
        fetchAttempts.removeValue(forKey: blobIDHex)
    }

    /// Drop partials + attempt counters so a manual retry can start clean.
    func resetFetch(blobIDHex: String) {
        cancelFetch(blobIDHex: blobIDHex)
        inboundChunks.removeValue(forKey: blobIDHex)
    }

    func markFetchFailed(blobIDHex: String) {
        resetFetch(blobIDHex: blobIDHex)
    }

    var attempts: [String: Int] { fetchAttempts }

    // MARK: - Private

    private func pushKey(peerUUID: UUID, blobIDHex: String) -> String {
        "\(peerUUID.uuidString)|\(blobIDHex.lowercased())"
    }

    private func completeFetch(blobIDHex: String) {
        inboundChunks.removeValue(forKey: blobIDHex)
        cancelFetch(blobIDHex: blobIDHex)
        onFetchTerminal?(blobIDHex, .ready)
    }

    private func scheduleRetry(
        blobIDHex: String,
        chunkCount: Int,
        from peerUUID: UUID,
        keyData: Data
    ) {
        fetchRetryTasks[blobIDHex]?.cancel()
        fetchRetryTasks[blobIDHex] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.fetchRetryDelay)
            guard !Task.isCancelled else { return }
            await self.retryFetch(
                blobIDHex: blobIDHex,
                chunkCount: chunkCount,
                from: peerUUID,
                keyData: keyData
            )
        }
    }

    private func retryFetch(
        blobIDHex: String,
        chunkCount: Int,
        from peerUUID: UUID,
        keyData: Data
    ) async {
        if blobStore.hasPlaintext(blobIDHex) {
            completeFetch(blobIDHex: blobIDHex)
            return
        }
        let attempt = (fetchAttempts[blobIDHex] ?? 0) + 1
        fetchAttempts[blobIDHex] = attempt
        if attempt > Self.maxFetchAttempts {
            markFetchFailed(blobIDHex: blobIDHex)
            onFetchTerminal?(blobIDHex, .failed)
            return
        }
        guard transport.hasDirectLink(to: peerUUID) else {
            scheduleRetry(
                blobIDHex: blobIDHex,
                chunkCount: chunkCount,
                from: peerUUID,
                keyData: keyData
            )
            return
        }
        if transport.hasMultipeerLink(to: peerUUID) {
            // Allow one more resource push attempt after timeout.
            pushedResources.remove(pushKey(peerUUID: peerUUID, blobIDHex: blobIDHex))
            let frame = WireFrame.blobRequest(
                senderUUID: transport.peerUUID,
                blobIDHex: blobIDHex,
                missingChunkIndexes: []
            )
            try? transport.sendDirect(frame, to: peerUUID)
        } else {
            let missing = missingChunks(for: blobIDHex, chunkCount: chunkCount)
            requestChunks(blobIDHex: blobIDHex, missing: missing, from: peerUUID)
        }
        scheduleRetry(
            blobIDHex: blobIDHex,
            chunkCount: chunkCount,
            from: peerUUID,
            keyData: keyData
        )
    }
}
