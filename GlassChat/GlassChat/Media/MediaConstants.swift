import CoreGraphics
import Foundation

enum MediaConstants {
    static let thumbnailMaxEdge: CGFloat = 256
    static let thumbnailMaxBytes = 16 * 1024
    static let fullMaxEdge: CGFloat = 1600
    /// Cap when a direct Multipeer link is available.
    static let multipeerMaxBytes = 1_000_000
    /// Cap when only BLE / multi-hop mesh is available.
    static let bleMaxBytes = 300_000
    /// Plaintext chunk size for BLE sealed-frame pull path.
    static let bleChunkSize = 2 * 1024
    static let blobStoreQuotaBytes = 50 * 1024 * 1024
    static let resourceNamePrefix = "blob/"
}
