import XCTest
import CryptoKit
@testable import GlassChat

final class EnvelopeCryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let aliceID = UUID()
        let bobID = UUID()
        let packetID = UUID()
        let aad = uuidData(packetID) + uuidData(aliceID) + uuidData(bobID)
        let plaintext = Data("hello mesh".utf8)

        let sealed = try EnvelopeCrypto.seal(
            plaintext: plaintext,
            to: bob.publicKey.rawRepresentation,
            myPrivate: alice,
            myUUID: aliceID,
            theirUUID: bobID,
            authenticatedData: aad
        )
        let opened = try EnvelopeCrypto.open(
            ciphertext: sealed,
            from: alice.publicKey.rawRepresentation,
            myPrivate: bob,
            myUUID: bobID,
            theirUUID: aliceID,
            authenticatedData: aad
        )
        XCTAssertEqual(opened, plaintext)
    }

    func testWrongKeyFails() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let eve = Curve25519.KeyAgreement.PrivateKey()
        let aad = Data("packet".utf8)
        let sealed = try EnvelopeCrypto.seal(
            plaintext: Data("secret".utf8),
            to: bob.publicKey.rawRepresentation,
            myPrivate: alice,
            myUUID: UUID(),
            theirUUID: UUID(),
            authenticatedData: aad
        )
        XCTAssertThrowsError(
            try EnvelopeCrypto.open(
                ciphertext: sealed,
                from: alice.publicKey.rawRepresentation,
                myPrivate: eve,
                myUUID: UUID(),
                theirUUID: UUID(),
                authenticatedData: aad
            )
        )
    }

    func testReflectedDirectionAADFails() throws {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let aliceID = UUID()
        let bobID = UUID()
        let packetID = UUID()
        let sealAAD = uuidData(packetID) + uuidData(aliceID) + uuidData(bobID)
        let reflectedAAD = uuidData(packetID) + uuidData(bobID) + uuidData(aliceID)

        let sealed = try EnvelopeCrypto.seal(
            plaintext: Data("ack-or-message".utf8),
            to: bob.publicKey.rawRepresentation,
            myPrivate: alice,
            myUUID: aliceID,
            theirUUID: bobID,
            authenticatedData: sealAAD
        )

        XCTAssertThrowsError(
            try EnvelopeCrypto.open(
                ciphertext: sealed,
                from: alice.publicKey.rawRepresentation,
                myPrivate: bob,
                myUUID: bobID,
                theirUUID: aliceID,
                authenticatedData: reflectedAAD
            )
        )
    }

    private func uuidData(_ uuid: UUID) -> Data {
        var data = Data()
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        return data
    }
}
