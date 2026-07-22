import Foundation
import MultipeerConnectivity
import Security
import UIKit

struct LocalIdentity {
    let peerUUID: UUID
    var displayName: String
    let mcPeerID: MCPeerID

    var shortID: String {
        String(peerUUID.uuidString.prefix(8)).uppercased()
    }

    enum Keys {
        static let displayName = "glasschat.displayName"
        static let peerUUID = "glasschat.peerUUID"
        static let mcPeerID = "glasschat.mcPeerID"
        static let nearbyVisible = "glasschat.nearbyVisible"
    }

    static var isNearbyVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.nearbyVisible) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.nearbyVisible)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.nearbyVisible) }
    }

    static var hasChosenDisplayName: Bool {
        UserDefaults.standard.string(forKey: Keys.displayName) != nil
    }

    static func loadOrCreate() -> LocalIdentity {
        let uuid = loadOrCreateUUID()
        let displayName = UserDefaults.standard.string(forKey: Keys.displayName)
            ?? UIDevice.current.name
        let mcPeerID = loadOrCreateMCPeerID(displayName: displayName, uuid: uuid)
        return LocalIdentity(peerUUID: uuid, displayName: displayName, mcPeerID: mcPeerID)
    }

    mutating func updateDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = trimmed
        UserDefaults.standard.set(trimmed, forKey: Keys.displayName)
        // MCPeerID displayName is immutable; keep archived ID stable.
        // Browsing UX uses hello frames for the real name.
    }

    private static func loadOrCreateUUID() -> UUID {
        if let existing = KeychainStore.string(forKey: Keys.peerUUID),
           let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let uuid = UUID()
        KeychainStore.set(uuid.uuidString, forKey: Keys.peerUUID)
        return uuid
    }

    private static func loadOrCreateMCPeerID(displayName: String, uuid: UUID) -> MCPeerID {
        if let data = UserDefaults.standard.data(forKey: Keys.mcPeerID),
           let peer = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return peer
        }
        let label = "\(displayName)#\(uuid.uuidString.prefix(4))"
        let peer = MCPeerID(displayName: String(label.prefix(63)))
        if let data = try? NSKeyedArchiver.archivedData(requiringSecureCoding: true, from: peer) {
            UserDefaults.standard.set(data, forKey: Keys.mcPeerID)
        }
        return peer
    }
}

enum KeychainStore {
    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
