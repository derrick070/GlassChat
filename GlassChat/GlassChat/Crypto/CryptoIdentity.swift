import Foundation
import CryptoKit

struct CryptoIdentity: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    static func loadOrCreate() -> CryptoIdentity {
        if let data = KeychainStore.data(forKey: Keys.privateKey),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return CryptoIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.setData(key.rawRepresentation, forKey: Keys.privateKey)
        return CryptoIdentity(privateKey: key)
    }

    private enum Keys {
        static let privateKey = "glasschat.privateKey"
    }
}
