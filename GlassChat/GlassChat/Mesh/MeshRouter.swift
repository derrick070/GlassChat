import Foundation

@MainActor
final class MeshRouter {
    static let maxTTL: UInt8 = 6
    private let seenCacheCapacity = 2000

    private var seen: [UUID] = []
    private var seenSet: Set<UUID> = []

    struct RelayAction {
        let packet: MeshPacket
        let encoded: Data
        let excludeLink: UUID?
        /// When false, mux should store but not rebroadcast (TTL exhausted).
        let shouldBroadcast: Bool
    }

    enum Outcome {
        case ignore
        case announce(AnnouncePayload, from: UUID)
        case deliverSealed(MeshPacket)
        case relay(RelayAction)
    }

    func noteSent(_ id: UUID) {
        remember(id)
    }

    func handleInbound(
        packet: MeshPacket,
        encoded: Data,
        fromLink linkUUID: UUID,
        myUUID: UUID
    ) -> Outcome {
        guard packet.version == MeshPacket.currentVersion else { return .ignore }
        guard packet.sourceUUID != myUUID else { return .ignore }

        // Already-seen packets: still deliver sealed frames addressed to us so a
        // lost ACK can recover when the sender retransmits the same packetID.
        if hasSeen(packet.packetID) {
            if packet.kind == .sealed, packet.destinationUUID == myUUID {
                return .deliverSealed(packet)
            }
            return .ignore
        }
        remember(packet.packetID)

        switch packet.kind {
        case .announce:
            guard let payload = try? JSONDecoder.wire.decode(AnnouncePayload.self, from: packet.payload) else {
                return .ignore
            }
            return .announce(payload, from: packet.sourceUUID)

        case .sealed:
            if packet.destinationUUID == myUUID {
                return .deliverSealed(packet)
            }
            if packet.ttl <= 1 {
                return .relay(
                    RelayAction(
                        packet: packet,
                        encoded: encoded,
                        excludeLink: linkUUID,
                        shouldBroadcast: false
                    )
                )
            }
            var forwarded = packet
            forwarded.ttl -= 1
            guard let encodedForward = try? forwarded.encode() else { return .ignore }
            return .relay(
                RelayAction(
                    packet: forwarded,
                    encoded: encodedForward,
                    excludeLink: linkUUID,
                    shouldBroadcast: true
                )
            )
        }
    }

    private func hasSeen(_ id: UUID) -> Bool {
        seenSet.contains(id)
    }

    private func remember(_ id: UUID) {
        if seenSet.insert(id).inserted {
            seen.append(id)
            if seen.count > seenCacheCapacity {
                let removed = seen.removeFirst()
                seenSet.remove(removed)
            }
        }
    }
}
