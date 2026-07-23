import Foundation
import CryptoKit

enum BlobCrypto {
    enum Error: Swift.Error {
        case sealFailed
        case openFailed
        case invalidKey
        case hashMismatch
    }

    /// Seal plaintext image bytes. Returns ciphertext, random key, and content-addressed blob ID.
    static func seal(_ plaintext: Data) throws -> (ciphertext: Data, keyData: Data, blobIDHex: String) {
        let key = SymmetricKey(size: .bits256)
        let box = try ChaChaPoly.seal(plaintext, using: key)
        let ciphertext = box.combined
        let blobIDHex = sha256Hex(ciphertext)
        return (ciphertext, key.withUnsafeBytes { Data($0) }, blobIDHex)
    }

    static func open(_ ciphertext: Data, keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw Error.invalidKey }
        let key = SymmetricKey(data: keyData)
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        do {
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw Error.openFailed
        }
    }

    static func verifyBlobID(_ ciphertext: Data, expectedHex: String) -> Bool {
        sha256Hex(ciphertext) == expectedHex.lowercased()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func chunkCount(forByteCount byteCount: Int, chunkSize: Int = MediaConstants.bleChunkSize) -> Int {
        guard byteCount > 0 else { return 0 }
        return (byteCount + chunkSize - 1) / chunkSize
    }

    static func chunk(of ciphertext: Data, index: Int, chunkSize: Int = MediaConstants.bleChunkSize) -> Data? {
        let start = index * chunkSize
        guard start < ciphertext.count else { return nil }
        let end = min(start + chunkSize, ciphertext.count)
        return ciphertext.subdata(in: start..<end)
    }
}
