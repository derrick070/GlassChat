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

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var inboxCharacteristic: CBMutableCharacteristic!
    private var outboxCharacteristic: CBMutableCharacteristic!
    private var identityCharacteristic: CBMutableCharacteristic!

    private var peerUUIDByPeripheral: [UUID: UUID] = [:] // peripheral.identifier → peerUUID
    private var peripheralByPeerUUID: [UUID: CBPeripheral] = [:]
    private var peripheralByID: [UUID: CBPeripheral] = [:]
    private var centralByPeer: [UUID: CBCentral] = [:]
    private var peerByCentralID: [UUID: UUID] = [:] // central.identifier → peerUUID

    private let linkContinuation: AsyncStream<LinkEvent>.Continuation
    let linkEvents: AsyncStream<LinkEvent>

    private var isRunning = false
    private var pendingWrites: [UUID: [Data]] = [:]
    private var pendingNotifies: [UUID: [Data]] = [:]

    init(identity: LocalIdentity) {
        self.identity = identity
        var continuation: AsyncStream<LinkEvent>.Continuation!
        self.linkEvents = AsyncStream { continuation = $0 }
        self.linkContinuation = continuation
        super.init()
    }

    func start() {
        isRunning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }
        startAdvertisingIfReady()
        startScanningIfReady()
    }

    func stop() {
        isRunning = false
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        resetCentralState(cancelConnections: true)
        resetPeripheralState(removeServices: true)
    }

    func refreshDiscovery() {
        guard isRunning else { return }
        central?.stopScan()
        startScanningIfReady()
        startAdvertisingIfReady()
    }

    func send(_ data: Data, to peerUUID: UUID) throws {
        var sent = false

        if let peripheral = peripheralByPeerUUID[peerUUID],
           let inbox = peripheral.services?
            .first(where: { $0.uuid == BLEConstants.serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid == BLEConstants.inboxCharacteristicUUID }) {
            let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            let fragments = BLEFragmenter.fragment(data, mtu: mtu)
            for fragment in fragments {
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(fragment, for: inbox, type: .withoutResponse)
                    sent = true
                } else {
                    pendingWrites[peerUUID, default: []].append(fragment)
                    sent = true
                }
            }
        }

        if let centralPeer = centralByPeer[peerUUID],
           let manager = peripheralManager,
           outboxCharacteristic != nil {
            let mtu = max(20, centralPeer.maximumUpdateValueLength)
            let fragments = BLEFragmenter.fragment(data, mtu: mtu)
            for fragment in fragments {
                let ok = manager.updateValue(
                    fragment,
                    for: outboxCharacteristic,
                    onSubscribedCentrals: [centralPeer]
                )
                if !ok {
                    pendingNotifies[peerUUID, default: []].append(fragment)
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
        guard isRunning, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startAdvertisingIfReady() {
        guard isRunning, let peripheralManager, peripheralManager.state == .poweredOn else { return }
        ensureGATT()
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: String(identity.shortID.prefix(8))
        ])
    }

    private func ensureGATT() {
        guard let peripheralManager else { return }
        if inboxCharacteristic != nil { return }
        var peerBytes = Data()
        withUnsafeBytes(of: identity.peerUUID.uuid) { peerBytes.append(contentsOf: $0) }

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
        identityCharacteristic = CBMutableCharacteristic(
            type: BLEConstants.identityCharacteristicUUID,
            properties: [.read],
            value: peerBytes,
            permissions: [.readable]
        )
        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [inboxCharacteristic, outboxCharacteristic, identityCharacteristic]
        peripheralManager.add(service)
    }

    private func resetCentralState(cancelConnections: Bool) {
        if cancelConnections, let central {
            for peripheral in peripheralByID.values {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        let peerIDs = Set(peerUUIDByPeripheral.values)
        for peerUUID in peerIDs {
            unregisterLink(peerUUID: peerUUID)
        }
        peerUUIDByPeripheral.removeAll()
        peripheralByPeerUUID.removeAll()
        peripheralByID.removeAll()
        pendingWrites.removeAll()
    }

    private func resetPeripheralState(removeServices: Bool) {
        let peerIDs = Set(centralByPeer.keys)
        for peerUUID in peerIDs {
            unregisterLink(peerUUID: peerUUID)
        }
        centralByPeer.removeAll()
        peerByCentralID.removeAll()
        pendingNotifies.removeAll()
        if removeServices, let peripheralManager {
            peripheralManager.removeAllServices()
            inboxCharacteristic = nil
            outboxCharacteristic = nil
            identityCharacteristic = nil
        }
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

    private func uuid(fromIdentityData data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Called by mux when an announce arrives over a provisional BLE central link.
    func remapProvisionalLink(from provisional: UUID, to realPeerUUID: UUID) {
        guard provisional != realPeerUUID else { return }
        if let central = centralByPeer.removeValue(forKey: provisional) {
            peerByCentralID[central.identifier] = realPeerUUID
            centralByPeer[realPeerUUID] = central
        }
        if let writes = pendingWrites.removeValue(forKey: provisional) {
            pendingWrites[realPeerUUID, default: []].append(contentsOf: writes)
        }
        if let notifies = pendingNotifies.removeValue(forKey: provisional) {
            pendingNotifies[realPeerUUID, default: []].append(contentsOf: notifies)
        }
        connectedLinkUUIDs.removeAll { $0 == provisional }
        if !connectedLinkUUIDs.contains(realPeerUUID) {
            connectedLinkUUIDs.append(realPeerUUID)
        }
        linkContinuation.yield(.linkDown(provisional))
        linkContinuation.yield(.linkUp(realPeerUUID))
    }
}

extension BLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                if isRunning {
                    startScanningIfReady()
                }
            } else {
                resetCentralState(cancelConnections: false)
            }
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
            guard connectedLinkUUIDs.count < BLEConstants.maxLinks else { return }
            guard peripheralByID[peripheral.identifier] == nil else { return }

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
            if let peerUUID = peerUUIDByPeripheral[id] {
                peripheralByPeerUUID.removeValue(forKey: peerUUID)
                unregisterLink(peerUUID: peerUUID)
            }
            peerUUIDByPeripheral.removeValue(forKey: id)
            peripheralByID.removeValue(forKey: id)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            peripheralByID.removeValue(forKey: peripheral.identifier)
        }
    }
}

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == BLEConstants.serviceUUID {
                peripheral.discoverCharacteristics(
                    [
                        BLEConstants.inboxCharacteristicUUID,
                        BLEConstants.outboxCharacteristicUUID,
                        BLEConstants.identityCharacteristicUUID
                    ],
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
            guard let identityChar = service.characteristics?
                .first(where: { $0.uuid == BLEConstants.identityCharacteristicUUID })
            else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.readValue(for: identityChar)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if characteristic.uuid == BLEConstants.identityCharacteristicUUID {
                handleIdentityRead(peripheral: peripheral, characteristic: characteristic)
                return
            }
            guard let data = characteristic.value,
                  let peerUUID = peerUUIDByPeripheral[peripheral.identifier]
            else { return }
            handleFragment(data, from: peerUUID)
        }
    }

    private func handleIdentityRead(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let data = characteristic.value, let remoteUUID = uuid(fromIdentityData: data) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        if remoteUUID == identity.peerUUID {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // Lower UUID initiates central role; higher UUID relies on reverse (peripheral) link.
        if identity.peerUUID.uuidString >= remoteUUID.uuidString {
            if centralByPeer[remoteUUID] != nil {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            // Reverse not up yet — keep this central link so we are not silent.
        }
        if peripheralByPeerUUID[remoteUUID] != nil {
            central?.cancelPeripheralConnection(peripheral)
            return
        }

        peerUUIDByPeripheral[peripheral.identifier] = remoteUUID
        peripheralByPeerUUID[remoteUUID] = peripheral

        if let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.serviceUUID }),
           let outbox = service.characteristics?.first(where: { $0.uuid == BLEConstants.outboxCharacteristicUUID }) {
            peripheral.setNotifyValue(true, for: outbox)
        }
        registerLink(peerUUID: remoteUUID)
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard let peerUUID = peerUUIDByPeripheral[peripheral.identifier],
                  var queue = pendingWrites[peerUUID],
                  let inbox = peripheral.services?
                    .first(where: { $0.uuid == BLEConstants.serviceUUID })?
                    .characteristics?
                    .first(where: { $0.uuid == BLEConstants.inboxCharacteristicUUID })
            else { return }
            while peripheral.canSendWriteWithoutResponse, !queue.isEmpty {
                let fragment = queue.removeFirst()
                peripheral.writeValue(fragment, for: inbox, type: .withoutResponse)
            }
            pendingWrites[peerUUID] = queue
        }
    }
}

extension BLETransport: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            if peripheral.state == .poweredOn {
                // Bluetooth came back — GATT was invalidated; republish.
                inboxCharacteristic = nil
                outboxCharacteristic = nil
                identityCharacteristic = nil
                if isRunning {
                    startAdvertisingIfReady()
                }
            } else {
                resetPeripheralState(removeServices: false)
                inboxCharacteristic = nil
                outboxCharacteristic = nil
                identityCharacteristic = nil
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        Task { @MainActor in
            guard isRunning else { return }
            for request in requests {
                guard let data = request.value else { continue }
                let peerUUID = peerByCentralID[request.central.identifier] ?? request.central.identifier
                handleFragment(data, from: peerUUID)
                // Inbox is writeWithoutResponse — no ATT response required.
            }
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            guard isRunning else { return }
            let provisional = central.identifier
            peerByCentralID[central.identifier] = provisional
            centralByPeer[provisional] = central
            registerLink(peerUUID: provisional)
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        Task { @MainActor in
            if let peerUUID = peerByCentralID.removeValue(forKey: central.identifier) {
                centralByPeer.removeValue(forKey: peerUUID)
                unregisterLink(peerUUID: peerUUID)
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in
            for (peerUUID, queue) in pendingNotifies {
                guard let central = centralByPeer[peerUUID], !queue.isEmpty else { continue }
                var remaining = queue
                while !remaining.isEmpty {
                    let fragment = remaining.removeFirst()
                    let ok = peripheralManager?.updateValue(
                        fragment,
                        for: outboxCharacteristic,
                        onSubscribedCentrals: [central]
                    ) ?? false
                    if !ok {
                        remaining.insert(fragment, at: 0)
                        break
                    }
                }
                pendingNotifies[peerUUID] = remaining
            }
        }
    }
}
