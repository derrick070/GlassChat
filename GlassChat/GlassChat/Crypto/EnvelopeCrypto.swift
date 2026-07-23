import Foundation
import CryptoKit

enum EnvelopeCrypto {
    enum Error: Swift.Error {
        case invalidPublicKey
        case openFailed
    }

    static func pairwiseKey(
        myPrivate: Curve25519.KeyAgreement.PrivateKey,
        theirPublicData: Data,
        myUUID: UUID,
        theirUUID: UUID
    ) throws -> SymmetricKey {
        guard let theirPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublicData) else {
            throw Error.invalidPublicKey
        }
        let shared = try myPrivate.sharedSecretFromKeyAgreement(with: theirPublic)
        let info = sortedUUIDBytes(myUUID, theirUUID)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("glasschat-v1".utf8),
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    static func seal(
        plaintext: Data,
        to theirPublicData: Data,
        myPrivate: Curve25519.KeyAgreement.PrivateKey,
        myUUID: UUID,
        theirUUID: UUID,
        authenticatedData: Data
    ) throws -> Data {
        let key = try pairwiseKey(
            myPrivate: myPrivate,
            theirPublicData: theirPublicData,
            myUUID: myUUID,
            theirUUID: theirUUID
        )
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: authenticatedData)
        return box.combined
    }

    static func open(
        ciphertext: Data,
        from theirPublicData: Data,
        myPrivate: Curve25519.KeyAgreement.PrivateKey,
        myUUID: UUID,
        theirUUID: UUID,
        authenticatedData: Data
    ) throws -> Data {
        let key = try pairwiseKey(
            myPrivate: myPrivate,
            theirPublicData: theirPublicData,
            myUUID: myUUID,
            theirUUID: theirUUID
        )
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: authenticatedData)
        } catch {
            throw Error.openFailed
        }
    }

    private static func sortedUUIDBytes(_ a: UUID, _ b: UUID) -> Data {
        let sa = a.uuidString
        let sb = b.uuidString
        let first = sa < sb ? a : b
        let second = sa < sb ? b : a
        var data = Data()
        withUnsafeBytes(of: first.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: second.uuid) { data.append(contentsOf: $0) }
        return data
    }
}
