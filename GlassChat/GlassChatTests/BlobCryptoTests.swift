import XCTest
@testable import GlassChat

final class BlobCryptoTests: XCTestCase {
    func testSealOpenRoundTripAndContentAddress() throws {
        let plaintext = Data(repeating: 0xAB, count: 12_345)
        let sealed = try BlobCrypto.seal(plaintext)
        XCTAssertEqual(sealed.blobIDHex, BlobCrypto.sha256Hex(sealed.ciphertext))
        XCTAssertTrue(BlobCrypto.verifyBlobID(sealed.ciphertext, expectedHex: sealed.blobIDHex))
        let opened = try BlobCrypto.open(sealed.ciphertext, keyData: sealed.keyData)
        XCTAssertEqual(opened, plaintext)
    }

    func testChunkingCoversAllBytes() throws {
        let plaintext = Data((0..<10_000).map { UInt8($0 % 251) })
        let sealed = try BlobCrypto.seal(plaintext)
        let count = BlobCrypto.chunkCount(forByteCount: sealed.ciphertext.count)
        XCTAssertGreaterThan(count, 1)
        var reassembled = Data()
        for index in 0..<count {
            let part = try XCTUnwrap(BlobCrypto.chunk(of: sealed.ciphertext, index: index))
            reassembled.append(part)
        }
        XCTAssertEqual(reassembled, sealed.ciphertext)
        let opened = try BlobCrypto.open(reassembled, keyData: sealed.keyData)
        XCTAssertEqual(opened, plaintext)
    }

    func testOpenRejectsWrongKey() throws {
        let sealed = try BlobCrypto.seal(Data("photo".utf8))
        let wrongKey = Data(repeating: 7, count: 32)
        XCTAssertThrowsError(try BlobCrypto.open(sealed.ciphertext, keyData: wrongKey))
    }
}
