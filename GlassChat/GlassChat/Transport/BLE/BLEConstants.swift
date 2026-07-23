import CoreBluetooth
import Foundation

enum BLEConstants {
    /// Fixed GlassChat mesh service UUID.
    static let serviceUUID = CBUUID(string: "6B1D8C20-3F8A-4E2B-9C7D-1A2B3C4D5E6F")
    static let inboxCharacteristicUUID = CBUUID(string: "6B1D8C21-3F8A-4E2B-9C7D-1A2B3C4D5E6F")
    static let outboxCharacteristicUUID = CBUUID(string: "6B1D8C22-3F8A-4E2B-9C7D-1A2B3C4D5E6F")
    /// Static readable peer UUID (16 raw bytes).
    static let identityCharacteristicUUID = CBUUID(string: "6B1D8C23-3F8A-4E2B-9C7D-1A2B3C4D5E6F")
    static let maxLinks = 6
    static let defaultWriteMTU = 182
}
