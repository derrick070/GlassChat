import XCTest
@testable import GlassChat

@MainActor
final class BlobStoreTests: XCTestCase {
    func testAssemblePersistsPlainAndCipher() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = BlobStore(rootURL: dir)
        let plaintext = Data(repeating: 0x3C, count: 5_000)
        let sealed = try BlobCrypto.seal(plaintext)
        let chunkCount = BlobCrypto.chunkCount(forByteCount: sealed.ciphertext.count)
        var chunks: [Int: Data] = [:]
        for index in 0..<chunkCount {
            chunks[index] = try XCTUnwrap(BlobCrypto.chunk(of: sealed.ciphertext, index: index))
        }

        let assembled = try store.assemble(
            blobIDHex: sealed.blobIDHex,
            chunks: chunks,
            expectedChunkCount: chunkCount,
            keyData: sealed.keyData
        )
        XCTAssertEqual(assembled, plaintext)
        XCTAssertTrue(store.hasCiphertext(sealed.blobIDHex))
        XCTAssertTrue(store.hasPlaintext(sealed.blobIDHex))
        XCTAssertEqual(store.plaintext(for: sealed.blobIDHex), plaintext)
    }
}
