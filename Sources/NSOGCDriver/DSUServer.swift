import Foundation
import Network

final class DSUServer: @unchecked Sendable {
  private static let allowedPorts = 26760...26764
  private static let maximumConnections = 16
  private static let maximumPacketSize = 1_024

  private let queue = DispatchQueue(label: "com.nso-gc-driver.dsu")
  private var listener: NWListener?
  private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
  private var clients: [String: Set<Int>] = [:]
  private var states: [Int: (ControllerState, ConnectionKind)] = [:]
  private var counter: UInt32 = 0
  private var rumble: [Int: (UInt8) -> Void] = [:]
  // Producers can run faster than Network.framework completes UDP sends.
  // Bound both handoffs and replace stale state with the newest sample.
  private let updateLock = NSLock()
  private var pendingUpdates: [Int: (ControllerState, ConnectionKind)] = [:]
  private var updateFlushScheduled = false
  private struct PadSendKey: Hashable {
    let connection: ObjectIdentifier
    let slot: Int
  }
  private struct PendingPadSend {
    let packet: [UInt8]
    let connection: NWConnection
  }
  private var pendingPadSends: [PadSendKey: PendingPadSend] = [:]
  private var padSendsInFlight = Set<PadSendKey>()
  private(set) var port: UInt16 = 26760
  var onLog: ((String) -> Void)?

  func start() -> Bool {
    queue.sync { startOnQueue() }
  }

  private func startOnQueue() -> Bool {
    guard listener == nil else { return true }
    return startListener(startingAt: Self.allowedPorts.lowerBound)
  }

  private func startListener(startingAt firstCandidate: Int) -> Bool {
    guard firstCandidate <= Self.allowedPorts.upperBound else {
      onLog?("Unable to bind DSU to 127.0.0.1 on ports 26760–26764")
      return false
    }
    for candidate in firstCandidate...Self.allowedPorts.upperBound {
      guard let candidatePort = NWEndpoint.Port(rawValue: UInt16(candidate)) else { continue }
      let parameters = NWParameters.udp
      parameters.requiredLocalEndpoint = .hostPort(
        host: "127.0.0.1", port: candidatePort)
      do {
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionLimit = Self.maximumConnections
        listener = newListener
        port = UInt16(candidate)
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
          guard let self, let newListener, self.listener === newListener else { return }
          switch state {
          case .ready:
            self.onLog?("DSU server listening on 127.0.0.1:\(candidate)")
          case .failed(let error):
            self.onLog?("DSU port \(candidate) is unavailable (\(error)); trying the next port")
            newListener.cancel()
            self.listener = nil
            _ = self.startListener(startingAt: candidate + 1)
          default:
            break
          }
        }
        newListener.newConnectionHandler = { [weak self] connection in
          self?.receive(connection)
        }
        newListener.start(queue: queue)
        return true
      } catch {
        continue
      }
    }
    onLog?("Unable to create a DSU listener on 127.0.0.1 ports 26760–26764")
    return false
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.listener?.cancel()
      self.listener = nil
      let connections = Array(self.activeConnections.values)
      self.activeConnections.removeAll()
      self.clients.removeAll()
      self.clientConnections.removeAll()
      self.states.removeAll()
      self.rumble.removeAll()
      self.pendingPadSends.removeAll()
      self.padSendsInFlight.removeAll()
      for connection in connections { connection.cancel() }
    }
  }
  func register(slot: Int, rumble callback: @escaping (UInt8) -> Void) {
    queue.sync { rumble[slot] = callback }
  }
  func update(_ state: ControllerState, slot: Int, kind: ConnectionKind) {
    updateLock.lock()
    pendingUpdates[slot] = (state, kind)
    let shouldSchedule = !updateFlushScheduled
    if shouldSchedule { updateFlushScheduled = true }
    updateLock.unlock()
    guard shouldSchedule else { return }
    queue.async { [weak self] in self?.flushPendingUpdates() }
  }
  func remove(slot: Int) {
    queue.async { [weak self] in
      guard let self else { return }
      self.states.removeValue(forKey: slot)
      self.sendToClients()
    }
  }
  func reset() {
    queue.async { [weak self] in
      guard let self else { return }
      self.states.removeAll()
      self.sendToClients()
    }
  }

  private func flushPendingUpdates() {
    updateLock.lock()
    let updates = pendingUpdates
    pendingUpdates.removeAll(keepingCapacity: true)
    updateFlushScheduled = false
    updateLock.unlock()
    for (slot, value) in updates { states[slot] = value }
    sendToClients()
  }

  private func receive(_ connection: NWConnection) {
    guard activeConnections.count < Self.maximumConnections else {
      connection.cancel()
      return
    }
    activeConnections[ObjectIdentifier(connection)] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .failed, .cancelled:
        self.remove(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveNext(connection)
  }
  private func receiveNext(_ c: NWConnection) {
    c.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      guard error == nil else {
        self.remove(c)
        c.cancel()
        return
      }
      if let data, data.count >= 20 { self.handle(data, connection: c) }
      self.receiveNext(c)
    }
  }
  private func remove(_ connection: NWConnection) {
    let key = String(describing: connection.endpoint)
    remove(key: key, connection: connection)
  }
  private func remove(key: String, connection: NWConnection? = nil) {
    if let connection {
      activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }
    // Do not remove a newer connection that happens to use the same
    // endpoint as the connection which just failed.
    if let connection, clientConnections[key] !== connection { return }
    clients.removeValue(forKey: key)
    clientConnections.removeValue(forKey: key)
    if let connection {
      let connectionID = ObjectIdentifier(connection)
      pendingPadSends = pendingPadSends.filter { $0.key.connection != connectionID }
      padSendsInFlight = padSendsInFlight.filter { $0.connection != connectionID }
    }
  }
  private func handle(_ data: Data, connection: NWConnection) {
    guard data.count <= Self.maximumPacketSize else { return }
    let b = [UInt8](data)
    guard isValidRequest(b) else { return }
    let type = le32(b, 16)
    let key = String(describing: connection.endpoint)
    clientConnections[key] = connection
    switch type {
    case 0x0010_0000: send(version(serverID: le32(b, 12)), to: connection)
    case 0x0010_0001: sendInfo(request: b, to: connection)
    case 0x0010_0002:
      clients[key] = requestedSlots(b)
      sendToClients()
    case 0x0011_0001: sendMotorInfo(request: b, to: connection)
    case 0x0011_0002: handleRumble(b)
    default: break
    }
  }
  private func requestedSlots(_ b: [UInt8]) -> Set<Int> {
    guard b.count > 21 else { return [0] }
    if b[20] == 0 { return [0, 1, 2, 3] }
    return [Int(b[21] & 3)]
  }
  private func sendToClients() {
    for (key, slots) in clients {
      guard let connection = clientConnections[key] else { continue }
      for slot in slots {
        guard let (state, kind) = states[slot] else { continue }
        enqueuePadData(
          padData(slot: slot, state: state, kind: kind), slot: slot, to: connection)
      }
    }
  }
  // NWConnection references are retained separately because endpoint descriptions are not sendable handles.
  private var clientConnections: [String: NWConnection] = [:]
  private func send(_ packet: [UInt8], to c: NWConnection) {
    let key = String(describing: c.endpoint)
    c.send(
      content: Data(packet),
      completion: .contentProcessed { [weak self, weak c] error in
        guard let self, let c, error != nil else { return }
        self.remove(key: key, connection: c)
        c.cancel()
      })
  }
  private func enqueuePadData(_ packet: [UInt8], slot: Int, to connection: NWConnection) {
    let key = PadSendKey(connection: ObjectIdentifier(connection), slot: slot)
    pendingPadSends[key] = PendingPadSend(packet: packet, connection: connection)
    guard !padSendsInFlight.contains(key) else { return }
    sendNextPadData(for: key)
  }
  private func sendNextPadData(for key: PadSendKey) {
    guard let pending = pendingPadSends.removeValue(forKey: key) else {
      padSendsInFlight.remove(key)
      return
    }
    padSendsInFlight.insert(key)
    pending.connection.send(
      content: Data(pending.packet),
      completion: .contentProcessed { [weak self, weak connection = pending.connection] error in
        guard let self else { return }
        guard let connection else {
          self.pendingPadSends.removeValue(forKey: key)
          self.padSendsInFlight.remove(key)
          return
        }
        if error != nil {
          self.remove(connection)
          connection.cancel()
        } else {
          // If newer state arrived while this datagram was being
          // processed, send only that newest state next.
          self.sendNextPadData(for: key)
        }
      })
  }
  private func sendInfo(request: [UInt8], to connection: NWConnection) {
    let count = request.count >= 24 ? min(Int(le32(request, 20)), 4) : 1
    let requested = (0..<count).compactMap { index -> Int? in
      let slot = request.count > 24 + index ? Int(request[24 + index]) : index
      return (0..<4).contains(slot) ? slot : nil
    }
    for slot in requested {
      send(
        padInfo(
          slot: slot, connected: states[slot] != nil,
          kind: states[slot]?.1 ?? .usb, battery: states[slot]?.0.battery,
          serverID: le32(request, 12)),
        to: connection)
    }
  }
  private func handleRumble(_ b: [UInt8]) {
    // The rumble packet starts with the same 8-byte controller identifier
    // as a subscription: flags at byte 20 and slot at byte 21.
    guard b.count >= 30 else { return }
    let slot = Int(b[21] & 3)
    rumble[slot]?(b[29])
  }
  private func crc(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (~(crc & 1) &+ 1)) }
    }
    return ~crc
  }
  private func isValidRequest(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 20,
      Array(bytes.prefix(4)) == [0x44, 0x53, 0x55, 0x43],
      Int(le16(bytes, 6)) + 16 == bytes.count
    else { return false }

    let expectedCRC = le32(bytes, 8)
    var crcBytes = bytes
    crcBytes[8...11] = [0, 0, 0, 0]
    return crc(crcBytes) == expectedCRC
  }
  private func finish(_ p: inout [UInt8]) {
    p[8...11] = [0, 0, 0, 0]
    put32(&p, 8, crc(p))
  }
  private func version(serverID: UInt32) -> [UInt8] {
    var p = Array(repeating: UInt8(0), count: 24)
    p[0...3] = [0x44, 0x53, 0x55, 0x53]
    put16(&p, 4, 1001)
    put16(&p, 6, 8)
    put32(&p, 12, serverID)
    put32(&p, 16, 0x0010_0000)
    put16(&p, 20, 1001)
    finish(&p)
    return p
  }
  private func padInfo(
    slot: Int, connected: Bool, kind: ConnectionKind, battery: ControllerBattery?,
    serverID: UInt32
  )
    -> [UInt8]
  {
    var p = Array(repeating: UInt8(0), count: 32)
    p[0...3] = [0x44, 0x53, 0x55, 0x53]
    put16(&p, 4, 1001)
    put16(&p, 6, 16)
    put32(&p, 12, serverID)
    put32(&p, 16, 0x0010_0001)
    p[20] = UInt8(slot)
    p[21] = connected ? 2 : 0
    p[22] = 2
    p[23] = connected ? kind.rawValue : 0
    p[24...29] = [0, 0x11, 0x22, 0x33, 0x44, UInt8(slot)]
    p[30] = connected ? dsuBattery(battery) : 0
    finish(&p)
    return p
  }
  private func sendMotorInfo(request: [UInt8], to c: NWConnection) {
    // Dolphin uses this optional DSU query before it enables rumble. The
    // NSO GameCube controller has one rumble motor.
    let slots: [Int]
    if request.count > 20, request[20] == 0 {
      slots = Array(0..<4)
    } else if request.count > 21 {
      slots = [Int(request[21] & 3)]
    } else {
      slots = [0]
    }
    for slot in slots {
      send(
        motorInfo(
          slot: slot, connected: states[slot] != nil, kind: states[slot]?.1 ?? .usb,
          battery: states[slot]?.0.battery, serverID: le32(request, 12)), to: c)
    }
  }
  private func motorInfo(
    slot: Int, connected: Bool, kind: ConnectionKind, battery: ControllerBattery?,
    serverID: UInt32
  )
    -> [UInt8]
  {
    var p = Array(repeating: UInt8(0), count: 32)
    p[0...3] = [0x44, 0x53, 0x55, 0x53]
    put16(&p, 4, 1001)
    put16(&p, 6, 16)
    put32(&p, 12, serverID)
    put32(&p, 16, 0x0011_0001)
    p[20] = UInt8(slot)
    p[21] = connected ? 2 : 0
    p[22] = 2
    p[23] = connected ? kind.rawValue : 0
    p[24...29] = [0, 0x11, 0x22, 0x33, 0x44, UInt8(slot)]
    p[30] = connected ? dsuBattery(battery) : 0
    p[31] = connected ? 1 : 0
    finish(&p)
    return p
  }
  private func padData(slot: Int, state: ControllerState, kind: ConnectionKind) -> [UInt8] {
    var p = Array(repeating: UInt8(0), count: 100)
    p[0...3] = [0x44, 0x53, 0x55, 0x53]
    put16(&p, 4, 1001)
    put16(&p, 6, 84)
    put32(&p, 12, 0)
    put32(&p, 16, 0x0010_0002)
    p[20] = UInt8(slot)
    p[21] = 2
    p[22] = 2
    p[23] = kind.rawValue
    p[24...29] = [0, 0x11, 0x22, 0x33, 0x44, UInt8(slot)]
    p[30] = dsuBattery(state.battery)
    p[31] = 1
    counter &+= 1
    put32(&p, 32, counter)

    let b = state.buttons
    // DSU uses PlayStation-positioned bit names. Map the GameCube labels
    // into those positions, then also fill the analog button fields below.
    if b["Dpad_Left"] == true { p[36] |= 0x80 }
    if b["Dpad_Down"] == true { p[36] |= 0x40 }
    if b["Dpad_Right"] == true { p[36] |= 0x20 }
    if b["Dpad_Up"] == true { p[36] |= 0x10 }
    if b["Start"] == true { p[36] |= 0x08 }
    if b["Z"] == true { p[36] |= 0x04 }
    if b["Y"] == true { p[37] |= 0x80 }
    if b["B"] == true { p[37] |= 0x40 }
    if b["A"] == true { p[37] |= 0x20 }
    if b["X"] == true { p[37] |= 0x10 }
    if b["R"] == true { p[37] |= 0x08 }
    if b["L"] == true { p[37] |= 0x04 }
    if b["ZL"] == true { p[37] |= 0x01 }
    if b["Home"] == true { p[38] = 1 }
    if b["Capture"] == true { p[39] = 1 }

    // Dolphin checks these analog values as well as the digital masks.
    p[44] = b["Dpad_Left"] == true ? 255 : 0
    p[45] = b["Dpad_Down"] == true ? 255 : 0
    p[46] = b["Dpad_Right"] == true ? 255 : 0
    p[47] = b["Dpad_Up"] == true ? 255 : 0
    p[48] = b["Y"] == true ? 255 : 0
    p[49] = b["B"] == true ? 255 : 0
    p[50] = b["A"] == true ? 255 : 0
    p[51] = b["X"] == true ? 255 : 0
    p[52] = b["R"] == true ? 255 : 0
    p[53] = b["L"] == true ? 255 : 0
    p[54] = state.rightTrigger
    p[55] = state.leftTrigger

    let (lx, ly) = normalize(state.leftX, state.leftY)
    let (rx, ry) = normalize(state.rightX, state.rightY)
    p[40] = byte(lx)
    p[41] = byte(-ly)
    p[42] = byte(rx)
    p[43] = byte(-ry)
    finish(&p)
    return p
  }
  private func normalize(_ x: Int, _ y: Int) -> (Double, Double) {
    let m = sqrt(Double(x * x + y * y))
    guard m > 0 else { return (0, 0) }
    let s = min(1, m / 1400) / m
    return (Double(x) * s, Double(y) * s)
  }
  private func dsuBattery(_ battery: ControllerBattery?) -> UInt8 {
    guard let battery else { return 0 }
    if battery.isCharging { return battery.level == 9 ? 0xef : 0xee }
    if battery.hasExternalPower && battery.level == 9 { return 0xef }
    switch battery.level {
    case 0: return 1
    case 1...2: return 2
    case 3...5: return 3
    case 6...7: return 4
    default: return 5
    }
  }
  private func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, Int(v * 127 + 128)))) }
  private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
  }
  private func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
  private func put16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) {
    b[i] = UInt8(v & 0xff)
    b[i + 1] = UInt8((v >> 8) & 0xff)
  }
  private func put32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
    b[i] = UInt8(v & 0xff)
    b[i + 1] = UInt8((v >> 8) & 0xff)
    b[i + 2] = UInt8((v >> 16) & 0xff)
    b[i + 3] = UInt8((v >> 24) & 0xff)
  }
}
