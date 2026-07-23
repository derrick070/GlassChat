import CoreBluetooth
import Foundation
import Observation

/// Dual-role Core Bluetooth link transport for the GlassChat mesh.
@Observable
@MainActor
final class BLETransport: NSObject, LinkTransport {
    private(set) var connectedLinkUUIDs: [UUID] = []

    private let identity: LocalIdentity
    private let reassembler = BLEReassembler()

    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var inboxCharacteristic: CBMutableCharacteristic!
    private var outboxCharacteristic: CBMutableCharacteristic!

    private var peerUUIDByPeripheral: [UUID: UUID] = [:] // peripheral.identifier → peerUUID
    private var peripheralByPeerUUID: [UUID: CBPeripheral] = [:]
    private var peripheralByID: [UUID: CBPeripheral] = [:]
    private var knownPeerFromAd: [UUID: UUID] = [:] // peripheral.identifier → peerUUID from ad
    private var subscribedCentrals: [UUID: UUID] = [:] // central.identifier → peerUUID
    private var centralIDByPeer: [UUID: UUID] = [:]

    private let linkContinuation: AsyncStream<LinkEvent>.Continuation
    let linkEvents: AsyncStream<LinkEvent>

    private var isRunning = false
    private var pendingOutbound: [UUID: [Data]] = [:]

    init(identity: LocalIdentity) {
        self.identity = identity
        var continuation: AsyncStream<LinkEvent>.Continuation!
        self.linkEvents = AsyncStream { continuation = $0 }
        self.linkContinuation = continuation
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func start() {
        isRunning = true
        startAdvertisingIfReady()
        startScanningIfReady()
    }

    func stop() {
        isRunning = false
        central.stopScan()
        peripheralManager.stopAdvertising()
        for peripheral in peripheralByID.values {
            central.cancelPeripheralConnection(peripheral)
        }
        peerUUIDByPeripheral.removeAll()
        peripheralByPeerUUID.removeAll()
        peripheralByID.removeAll()
        knownPeerFromAd.removeAll()
        subscribedCentrals.removeAll()
        centralIDByPeer.removeAll()
        connectedLinkUUIDs = []
        pendingOutbound.removeAll()
    }

    func refreshDiscovery() {
        guard isRunning else { return }
        central.stopScan()
        startScanningIfReady()
        startAdvertisingIfReady()
    }

    func send(_ data: Data, to peerUUID: UUID) throws {
        let fragments = BLEFragmenter.fragment(data, mtu: BLEConstants.defaultWriteMTU)
        var sent = false

        if let peripheral = peripheralByPeerUUID[peerUUID],
           let inbox = peripheral.services?
            .first(where: { $0.uuid == BLEConstants.serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid == BLEConstants.inboxCharacteristicUUID }) {
            for fragment in fragments {
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(fragment, for: inbox, type: .withoutResponse)
                    sent = true
                } else {
                    pendingOutbound[peerUUID, default: []].append(fragment)
                    sent = true
                }
            }
        }

        if let _ = centralIDByPeer[peerUUID], outboxCharacteristic != nil {
            for fragment in fragments {
                let ok = peripheralManager.updateValue(
                    fragment,
                    for: outboxCharacteristic,
                    onSubscribedCentrals: nil
                )
                if !ok {
                    pendingOutbound[peerUUID, default: []].append(fragment)
                }
                sent = true
            }
        }

        guard sent else { throw TransportError.noConnectedPeers }
    }

    func broadcast(_ data: Data, excluding: UUID?) {
        for uuid in connectedLinkUUIDs where uuid != excluding {
            try? send(data, to: uuid)
        }
    }

    private func startScanningIfReady() {
        guard isRunning, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startAdvertisingIfReady() {
        guard isRunning, peripheralManager.state == .poweredOn else { return }
        ensureGATT()
        var peerBytes = Data()
        withUnsafeBytes(of: identity.peerUUID.uuid) { peerBytes.append(contentsOf: $0) }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: String(identity.shortID.prefix(8)),
            CBAdvertisementDataServiceDataKey: [BLEConstants.serviceUUID: peerBytes]
        ])
    }

    private func ensureGATT() {
        guard inboxCharacteristic == nil else { return }
        inboxCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.inboxCharacteristicUUID,
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        outboxCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.outboxCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [inboxCharacteristic, outboxCharacteristic]
        peripheralManager.add(service)
    }

    private func registerLink(peerUUID: UUID) {
        guard peerUUID != identity.peerUUID else { return }
        if !connectedLinkUUIDs.contains(peerUUID) {
            connectedLinkUUIDs.append(peerUUID)
            linkContinuation.yield(.linkUp(peerUUID))
        }
    }

    private func unregisterLink(peerUUID: UUID) {
        connectedLinkUUIDs.removeAll { $0 == peerUUID }
        linkContinuation.yield(.linkDown(peerUUID))
    }

    private func handleFragment(_ fragment: Data, from peerUUID: UUID) {
        guard let complete = reassembler.ingest(fragment) else { return }
        linkContinuation.yield(.dataReceived(complete, from: peerUUID))
    }

    private func peerUUID(from advertisementData: [String: Any]) -> UUID? {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = serviceData[BLEConstants.serviceUUID],
              data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension BLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            startScanningIfReady()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard isRunning else { return }
            if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                linkContinuation.yield(.discoveredName(name))
            }
            guard let peerUUID = peerUUID(from: advertisementData) else { return }
            guard peerUUID != identity.peerUUID else { return }
            // Tie-break: only the lower UUID initiates central connection.
            guard identity.peerUUID.uuidString < peerUUID.uuidString else { return }
            guard connectedLinkUUIDs.count < BLEConstants.maxLinks else { return }
            guard peripheralByPeerUUID[peerUUID] == nil else { return }

            knownPeerFromAd[peripheral.identifier] = peerUUID
            peripheralByID[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([BLEConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let id = peripheral.identifier
            if let peerUUID = peerUUIDByPeripheral[id] ?? knownPeerFromAd[id] {
                peripheralByPeerUUID.removeValue(forKey: peerUUID)
                unregisterLink(peerUUID: peerUUID)
            }
            peerUUIDByPeripheral.removeValue(forKey: id)
            peripheralByID.removeValue(forKey: id)
            knownPeerFromAd.removeValue(forKey: id)
        }
    }
}

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == BLEConstants.serviceUUID {
                peripheral.discoverCharacteristics(
                    [BLEConstants.inboxCharacteristicUUID, BLEConstants.outboxCharacteristicUUID],
                    for: service
                )
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard let peerUUID = knownPeerFromAd[peripheral.identifier] else { return }
            peerUUIDByPeripheral[peripheral.identifier] = peerUUID
            peripheralByPeerUUID[peerUUID] = peripheral
            if let outbox = service.characteristics?.first(where: { $0.uuid == BLEConstants.outboxCharacteristicUUID }) {
                peripheral.setNotifyValue(true, for: outbox)
            }
            registerLink(peerUUID: peerUUID)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard let data = characteristic.value,
                  let peerUUID = peerUUIDByPeripheral[peripheral.identifier] ?? knownPeerFromAd[peripheral.identifier]
            else { return }
            handleFragment(data, from: peerUUID)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let peerUUID = peerUUIDByPeripheral[peripheral.identifier],
                  var queue = pendingOutbound[peerUUID],
                  let inbox = peripheral.services?
                    .first(where: { $0.uuid == BLEConstants.serviceUUID })?
                    .characteristics?
                    .first(where: { $0.uuid == BLEConstants.inboxCharacteristicUUID })
            else { return }
            while peripheral.canSendWriteWithoutResponse, !queue.isEmpty {
                let fragment = queue.removeFirst()
                peripheral.writeValue(fragment, for: inbox, type: .withoutResponse)
            }
            pendingOutbound[peerUUID] = queue
        }
    }
}

extension BLETransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            startAdvertisingIfReady()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        Task { @MainActor in
            for request in requests {
                if let data = request.value {
                    // Until announce maps the central, buffer under a placeholder derived from central UUID.
                    // Announce handling in mux will call notePeripheralPeer if needed; for writes we use
                    // subscribed mapping when available, else temporary.
                    let centralID = request.central.identifier
                    if let peerUUID = subscribedCentrals[centralID] {
                        handleFragment(data, from: peerUUID)
                    } else {
                        // Stash against central ID as temporary peer key via first announce decode path:
                        // use central UUID as provisional and rewrite on announce — simplified: drop until mapped.
                        // Map provisional: use centralID as UUID-compatible key by hashing into UUID namespace.
                        let provisional = centralID
                        // Store reverse so announce can upgrade — for v1 require announce via notify path first.
                        // Accept writes only after subscription handshake sets mapping in didSubscribe.
                        _ = provisional
                        // Try decode announce from complete packet later; for now attempt reassembly keyed by central.
                        if let peerUUID = subscribedCentrals[centralID] {
                            handleFragment(data, from: peerUUID)
                        } else {
                            // Provisional link using central identifier as peer until announce arrives.
                            handleFragment(data, from: centralID)
                        }
                    }
                }
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            // Wait for announce to learn peer UUID; use central.identifier provisionally.
            let provisional = central.identifier
            subscribedCentrals[central.identifier] = provisional
            centralIDByPeer[provisional] = central.identifier
            registerLink(peerUUID: provisional)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if let peerUUID = subscribedCentrals.removeValue(forKey: central.identifier) {
                centralIDByPeer.removeValue(forKey: peerUUID)
                unregisterLink(peerUUID: peerUUID)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            // Drain a shallow global pending queue best-effort.
            for (peerUUID, queue) in pendingOutbound {
                guard !queue.isEmpty else { continue }
                var remaining = queue
                while !remaining.isEmpty {
                    let fragment = remaining.removeFirst()
                    let ok = peripheralManager.updateValue(
                        fragment,
                        for: outboxCharacteristic,
                        onSubscribedCentrals: nil
                    )
                    if !ok {
                        remaining.insert(fragment, at: 0)
                        break
                    }
                }
                pendingOutbound[peerUUID] = remaining
            }
        }
    }

    /// Called by mux when an announce arrives over a provisional BLE central link.
    func remapProvisionalLink(from provisional: UUID, to realPeerUUID: UUID) {
        guard provisional != realPeerUUID else { return }
        if let centralID = centralIDByPeer.removeValue(forKey: provisional) {
            subscribedCentrals[centralID] = realPeerUUID
            centralIDByPeer[realPeerUUID] = centralID
        }
        connectedLinkUUIDs.removeAll { $0 == provisional }
        if !connectedLinkUUIDs.contains(realPeerUUID) {
            connectedLinkUUIDs.append(realPeerUUID)
        }
        linkContinuation.yield(.linkDown(provisional))
        linkContinuation.yield(.linkUp(realPeerUUID))
    }
}
