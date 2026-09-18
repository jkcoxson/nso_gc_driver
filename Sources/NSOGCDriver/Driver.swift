@preconcurrency import CoreBluetooth
import Foundation
import IOKit.hid
import Network

// Nintendo Switch Online GameCube controller constants.
enum NSOConstants {
  static let controllerName = "GameCube Controller"
  static let vendorID: Int = 0x057e
  static let productID: Int = 0x2073
  static let bluetoothCompanyID: Int = 0x0553
  static let reportCharacteristic = CBUUID(string: "2A4D")
  // Expanded UUIDs used by the NSO GameCube controller's custom GATT
  // service. The short handle values are not valid UUID comparisons in
  // CoreBluetooth.
  static let bleInputCharacteristic = CBUUID(string: "8261cba1-9435-420c-84d6-f0c75a2c8e4d")
  static let bleCommandCharacteristic = CBUUID(string: "af95885e-44b3-4a24-9cf0-483cc129469a")
  static let bleBasicCommandCharacteristic = CBUUID(
    string: "649d4ac9-8eb7-4e6c-af44-1ea54fe5f005")
  // The SW2/NSO controller needs this request before it starts sending input.
  static let bleHandshake: [UInt8] = [
    0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,
    0x40, 0x7e, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00,
  ]
  static let defaultReport: [UInt8] = [
    0x03, 0x91, 0x00, 0x0d, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff,
  ]
  static let inputMode: [UInt8] = [
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x30,
  ]
  // Command 0x09/0x07 uses a one-hot player LED bitmask.
  static let ledMap: [UInt8] = [0x01, 0x02, 0x04, 0x08]
}

/// Power information included in the NSO controller's 0x0A input report.
/// The hardware reports ten discrete levels (0...9), so the percentage is
/// necessarily an approximation rather than a continuous measurement.
struct ControllerBattery: Equatable {
  let level: Int
  let isCharging: Bool
  let hasExternalPower: Bool

  init?(powerInfo: UInt8) {
    let reportedLevel = Int((powerInfo >> 2) & 0x0f)
    guard reportedLevel <= 9 else { return nil }
    level = reportedLevel
    isCharging = powerInfo & 0x02 != 0
    hasExternalPower = powerInfo & 0x01 != 0
  }

  var percentage: Int {
    Int((Double(level) * 100.0 / 9.0).rounded())
  }
}

struct ControllerState: Equatable {
  var buttons: [String: Bool] = [:]
  var leftX = 0, leftY = 0, rightX = 0, rightY = 0
  var leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0
  var battery: ControllerBattery?
  var raw = [UInt8]()

  // Raw reports may contain transport counters or unrelated status bytes that
  // change even when the controls do not. Only decoded controls and battery
  // state participate in equality, preventing idle UI/HID churn while still
  // publishing power changes. DSU heartbeats are handled separately.
  static func == (lhs: ControllerState, rhs: ControllerState) -> Bool {
    lhs.buttons == rhs.buttons
      && lhs.leftX == rhs.leftX && lhs.leftY == rhs.leftY
      && lhs.rightX == rhs.rightX && lhs.rightY == rhs.rightY
      && lhs.leftTrigger == rhs.leftTrigger && lhs.rightTrigger == rhs.rightTrigger
      && lhs.battery == rhs.battery
  }
}

enum ConnectionKind: UInt8 {
  case usb = 1
  case bluetooth = 2
}

func command(_ opcode: UInt8, interface: UInt8, subcommand: UInt8, value: UInt8 = 0) -> [UInt8] {
  [opcode, 0x91, interface, subcommand, 0, 0x08, 0, 0, value, 0, 0, 0, 0, 0, 0, 0]
}

func ledCommand(slot: Int, interface: UInt8) -> [UInt8] {
  let led = NSOConstants.ledMap[min(max(slot, 0), NSOConstants.ledMap.count - 1)]
  return [0x09, 0x91, interface, 0x07, 0, 0x08, 0, 0, led, 0, 0, 0, 0, 0, 0, 0]
}

final class InputDecoder {
  var center = (x: 2048, y: 2048, cx: 2048, cy: 2048)
  private var calibrationSamples: [(Int, Int, Int, Int)] = []
  private var calibrationReportsToSkip = 5
  private var leftStickDeadzone = 24
  private var rightStickDeadzone = 24
  private var bleHasReportID: Bool?
  private var sawAmbiguousBLEReport = false
  private var leftTriggerFilter = TriggerFilter()
  private var rightTriggerFilter = TriggerFilter()

  // Calibrate the trigger's nonzero rest point without delaying input by a
  // report. Its raw value is reported immediately after normalization.
  private struct TriggerFilter {
    private var releasedSamples: [Int] = []
    private var zero = 0x24
    private var maximum = 0xc0

    mutating func apply(raw: UInt8, digitalPressed: Bool) -> UInt8 {
      let value = Int(raw)

      // The raw trigger does not start at zero and its rest point varies
      // per controller. Learn that point only from low, unclicked samples.
      if !digitalPressed && value < 0x70 && releasedSamples.count < 32 {
        releasedSamples.append(value)
        if releasedSamples.count >= 8 {
          // A low percentile learns the real rest point even if the
          // user lightly holds the trigger during some early reports.
          let sorted = releasedSamples.sorted()
          zero = sorted[sorted.count / 5]
        }
      }
      maximum = max(maximum, value)

      // Leave a few raw counts for sensor noise at the released end, then
      // expand the usable travel back to the full DSU/HID byte range.
      let floor = zero + 4
      let normalized: Int
      if value <= floor || maximum <= floor {
        normalized = 0
      } else {
        normalized = min(255, (value - floor) * 255 / (maximum - floor))
      }

      return UInt8(normalized)
    }
  }

  func decode(_ data: [UInt8], bluetooth: Bool = false, offset: Int = 0) -> ControllerState? {
    guard offset >= 0 else { return nil }
    // macOS may remove the HID report ID, leaving the native BLE report at
    // 11 bytes. USB and full BLE reports are longer.
    guard data.count >= (bluetooth ? 11 : 15) + offset else { return nil }
    let o = offset
    // The common 63-byte BLE notification is ID-stripped. Lock the layout
    // for the connection instead of re-deciding from byte 0, which is a
    // rolling counter and can occasionally equal report ID 0x30.
    let fullBLEReport: Bool
    if bluetooth, data[0] != 0x3f || data.count != 12 {
      if let knownLayout = bleHasReportID {
        fullBLEReport = knownLayout
      } else if data.count == 63 || data[0] != 0x30 {
        if data.count >= 63 { bleHasReportID = false }
        fullBLEReport = false
      } else if data.count < 16 {
        fullBLEReport = false
      } else if !sawAmbiguousBLEReport {
        // One 0x30-valued counter sample is not enough to conclude
        // that a report ID is present. Skip this startup sample only.
        sawAmbiguousBLEReport = true
        return nil
      } else {
        bleHasReportID = true
        fullBLEReport = true
      }
    } else {
      fullBLEReport = false
    }
    // Report 0x0A stores Power Info after its rolling counter. USB includes
    // the report ID at byte 0; CoreBluetooth normally strips that ID. The
    // legacy 12-byte 0x3f report has no battery field.
    let isLegacySimpleReport = bluetooth && data.count == 12 && data[0] == 0x3f
    let powerInfoIndex = (bluetooth && !fullBLEReport ? 1 : 2) + o
    let battery =
      !isLegacySimpleReport && data.indices.contains(powerInfoIndex)
      ? ControllerBattery(powerInfo: data[powerInfoIndex]) : nil
    var buttons: [String: Bool] = [:]
    if bluetooth {
      // Short 0x3f reports use 16-bit axes and have a different button
      // layout from the normal 0x30 report.
      if data.count >= 63 && !fullBLEReport {
        // Discovered NSO BLE report: buttons are in the USB-style
        // order B, A, Y, X at bytes 2-4; sticks begin at byte 5.
        let b2 = data[2 + o]
        let b3 = data[3 + o]
        let b4 = data[4 + o]
        buttons = [
          "B": b2 & 1 != 0, "A": b2 & 2 != 0, "Y": b2 & 4 != 0, "X": b2 & 8 != 0,
          "R": b2 & 0x10 != 0, "Z": b2 & 0x20 != 0, "Start": b2 & 0x40 != 0,
          "Dpad_Down": b3 & 1 != 0, "Dpad_Right": b3 & 2 != 0,
          "Dpad_Left": b3 & 4 != 0, "Dpad_Up": b3 & 8 != 0,
          "L": b3 & 0x10 != 0, "ZL": b3 & 0x20 != 0,
          "Home": b4 & 1 != 0, "Capture": b4 & 2 != 0,
        ]
      } else if data[0] == 0x3f {
        guard data.count >= 12 + offset else { return nil }
        let b1 = data[1 + offset]
        let b2 = data[2 + offset]
        let buttons: [String: Bool] = [
          "Dpad_Down": b1 & 1 != 0, "Dpad_Right": b1 & 2 != 0,
          "Dpad_Left": b1 & 4 != 0, "Dpad_Up": b1 & 8 != 0,
          "Start": b2 & 2 != 0, "Home": b2 & 0x10 != 0,
          "Capture": b2 & 0x20 != 0, "L": b2 & 0x40 != 0,
          "Z": b2 & 0x80 != 0, "Y": false, "X": false,
          "B": false, "A": false, "R": false, "ZL": false,
        ]
        func wideAxis(_ i: Int) -> (Int, Int) {
          (
            Int(data[i + o]) | Int(data[i + 1 + o]) << 8,
            Int(data[i + 2 + o]) | Int(data[i + 3 + o]) << 8
          )
        }
        let main = wideAxis(4)
        let right = wideAxis(8)
        return condition(
          buttons: buttons, main: (main.0 - 32768, main.1 - 32768),
          right: (right.0 - 32768, right.1 - 32768),
          rawLeftTrigger: b2 & 0x40 != 0 ? 255 : 0,
          rawRightTrigger: b2 & 0x80 != 0 ? 255 : 0, battery: nil, raw: data,
          triggersAreAnalog: false)
      }
      // CoreBluetooth commonly strips the HID report ID. The Python bridge
      // handled both full 0x30 reports and the shortened 11-byte form.
      // Long BLE notifications have already had their HID report ID
      // removed. Byte 0 is a rolling counter, which can itself become
      // 0x30; never treat that counter value as a layout switch.
      let stripped = !fullBLEReport
      let buttonBase = stripped ? 2 : 3
      let b3 = data[buttonBase + o]
      let b4 = data[buttonBase + 1 + o]
      let b5 = data[buttonBase + 2 + o]
      if data.count >= 63 && !fullBLEReport {
        // Already decoded above.
      } else if data[0] == 0x3f {
        buttons = [
          "B": b3 & 1 != 0, "A": b3 & 2 != 0, "Y": b3 & 4 != 0, "X": b3 & 8 != 0,
          "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b3 & 0x40 != 0,
          "Dpad_Down": b4 & 1 != 0, "Dpad_Right": b4 & 2 != 0, "Dpad_Left": b4 & 4 != 0,
          "Dpad_Up": b4 & 8 != 0, "L": b4 & 0x10 != 0, "ZL": b4 & 0x20 != 0,
          "Home": b5 & 1 != 0, "Capture": b5 & 2 != 0,
        ]
      } else {
        buttons = [
          "Y": b3 & 1 != 0, "X": b3 & 2 != 0, "B": b3 & 4 != 0, "A": b3 & 8 != 0,
          "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b4 & 2 != 0,
          "Dpad_Down": b5 & 1 != 0, "Dpad_Up": b5 & 2 != 0, "Dpad_Right": b5 & 4 != 0,
          "Dpad_Left": b5 & 8 != 0, "L": b5 & 0x40 != 0, "ZL": b5 & 0x80 != 0,
          "Home": b4 & 0x10 != 0, "Capture": b4 & 0x20 != 0,
        ]
      }
    } else {
      let b3 = data[3 + o]
      let b4 = data[4 + o]
      let b5 = data[5 + o]
      buttons = [
        "B": b3 & 1 != 0, "A": b3 & 2 != 0, "Y": b3 & 4 != 0, "X": b3 & 8 != 0,
        "R": b3 & 0x10 != 0, "Z": b3 & 0x20 != 0, "Start": b3 & 0x40 != 0,
        "Dpad_Down": b4 & 1 != 0, "Dpad_Right": b4 & 2 != 0, "Dpad_Left": b4 & 4 != 0,
        "Dpad_Up": b4 & 8 != 0, "L": b4 & 0x10 != 0, "ZL": b4 & 0x20 != 0,
        "Home": b5 & 1 != 0, "Capture": b5 & 2 != 0,
      ]
    }
    let strippedBLE = bluetooth && !fullBLEReport
    let stickBase = strippedBLE ? 5 : 6
    // The USB report includes the report ID at byte 0, so its payload is
    // shifted by one byte relative to the native BLE report. The payload
    // layout is: 3 button bytes, 3-byte left stick, 3-byte right stick,
    // one status byte, then the L/R analog triggers. Therefore the USB
    // trigger bytes are 13/14, not 14/15. BLE's long 0x0A report uses
    // bytes 12/13; the shorter BLE form uses 13/14.
    let triggerBase = strippedBLE ? (data.count >= 63 ? 12 : 13) : 13
    func axis(_ i: Int) -> (Int, Int) {
      let x = Int(data[i + o]) | (Int(data[i + 1 + o] & 0x0f) << 8)
      let y = Int(data[i + 1 + o] >> 4) | (Int(data[i + 2 + o]) << 4)
      return (x, y)
    }
    guard data.count >= stickBase + 6 + o else { return nil }
    let main = axis(stickBase)
    let right = axis(stickBase + 3)
    // The octagonal gate cannot put both axes of either stick near the
    // electrical minimum at once. Zero-filled or misaligned reports can,
    // and would otherwise map to a simultaneous bottom-left jump.
    guard !(main.0 < 128 && main.1 < 128),
      !(right.0 < 128 && right.1 < 128)
    else { return nil }
    calibrate(main: main, right: right)
    let hasAnalogTriggers = data.count >= triggerBase + 2 + o
    return condition(
      buttons: buttons, main: (main.0 - center.x, main.1 - center.y),
      right: (right.0 - center.cx, right.1 - center.cy),
      rawLeftTrigger: hasAnalogTriggers ? data[triggerBase + o] : 0,
      rawRightTrigger: hasAnalogTriggers ? data[triggerBase + 1 + o] : 0,
      battery: battery, raw: data, triggersAreAnalog: hasAnalogTriggers)
  }

  private func calibrate(main: (Int, Int), right: (Int, Int)) {
    guard calibrationSamples.count < 50 else { return }
    if calibrationReportsToSkip > 0 {
      calibrationReportsToSkip -= 1
      return
    }

    // Startup reports can arrive while a stick is being moved. Only use
    // samples plausibly close to the nominal 12-bit center, and use medians
    // so an isolated bad report cannot drag the learned center away.
    guard distance(main.0 - 2048, main.1 - 2048) < 256,
      distance(right.0 - 2048, right.1 - 2048) < 256
    else { return }
    calibrationSamples.append((main.0, main.1, right.0, right.1))
    guard calibrationSamples.count == 50 else { return }

    center = (
      median(calibrationSamples.map { $0.0 }),
      median(calibrationSamples.map { $0.1 }),
      median(calibrationSamples.map { $0.2 }),
      median(calibrationSamples.map { $0.3 })
    )
    let leftNoise = calibrationSamples.map { distance($0.0 - center.x, $0.1 - center.y) }
    let rightNoise = calibrationSamples.map { distance($0.2 - center.cx, $0.3 - center.cy) }
    leftStickDeadzone = learnedDeadzone(leftNoise)
    rightStickDeadzone = learnedDeadzone(rightNoise)
  }

  private func condition(
    buttons: [String: Bool], main: (Int, Int), right: (Int, Int),
    rawLeftTrigger: UInt8, rawRightTrigger: UInt8, battery: ControllerBattery?, raw: [UInt8],
    triggersAreAnalog: Bool = true
  ) -> ControllerState {
    let left = conditionStick(main, deadzone: leftStickDeadzone)
    let right = conditionStick(right, deadzone: rightStickDeadzone)
    return ControllerState(
      buttons: buttons, leftX: left.0, leftY: left.1,
      rightX: right.0, rightY: right.1,
      leftTrigger: triggersAreAnalog
        ? leftTriggerFilter.apply(raw: rawLeftTrigger, digitalPressed: buttons["L"] == true)
        : (buttons["L"] == true ? 255 : 0),
      rightTrigger: triggersAreAnalog
        ? rightTriggerFilter.apply(raw: rawRightTrigger, digitalPressed: buttons["R"] == true)
        : (buttons["R"] == true ? 255 : 0),
      battery: battery, raw: raw)
  }

  private func conditionStick(_ stick: (Int, Int), deadzone: Int) -> (Int, Int) {
    let magnitude = distance(stick.0, stick.1)
    guard magnitude > deadzone else { return (0, 0) }

    // Remove only the measured center-noise radius, then stretch the rest
    // of the travel slightly so the gate does not cost fine control or range.
    let expectedRange = 1400.0
    let adjustedMagnitude =
      (Double(magnitude - deadzone) * expectedRange)
      / max(1, expectedRange - Double(deadzone))
    let scale = adjustedMagnitude / Double(magnitude)
    return (
      Int((Double(stick.0) * scale).rounded()),
      Int((Double(stick.1) * scale).rounded())
    )
  }

  private func learnedDeadzone(_ noise: [Int]) -> Int {
    let sorted = noise.sorted()
    let percentile95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    return min(64, max(24, percentile95 + 8))
  }

  private func distance(_ x: Int, _ y: Int) -> Int {
    Int(hypot(Double(x), Double(y)).rounded())
  }

  private func median(_ values: [Int]) -> Int {
    values.sorted()[values.count / 2]
  }
}

final class HIDTransport: @unchecked Sendable {
  private static let maximumInputReportLength = 64

  private let queue = DispatchQueue(label: "com.nso-gc-driver.usb-hid", qos: .userInteractive)
  private var manager: IOHIDManager?
  fileprivate final class Session {
    let registryID: UInt64
    let identifier: String
    var commandConnection: OpaquePointer?
    var playerSlot: Int

    init(
      registryID: UInt64, identifier: String, commandConnection: OpaquePointer, playerSlot: Int
    ) {
      self.registryID = registryID
      self.identifier = identifier
      self.commandConnection = commandConnection
      self.playerSlot = playerSlot
    }
  }

  private var sessions: [UInt64: Session] = [:]
  private var stopping = false
  var onReport: ((String, [UInt8]) -> Void)?
  var onConnected: ((String, String, ConnectionKind) -> Void)?
  var onDisconnected: ((String) -> Void)?
  var onLog: ((String) -> Void)?

  func start() -> Bool {
    queue.async { [weak self] in
      _ = self?.startOnQueue()
    }
    return true
  }

  private func startOnQueue() -> Bool {
    guard manager == nil else { return true }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let criteria: [[String: Any]] = [
      [
        kIOHIDVendorIDKey as String: NSOConstants.vendorID,
        kIOHIDProductIDKey as String: NSOConstants.productID,
      ]
    ]
    IOHIDManagerSetDeviceMatchingMultiple(m, criteria as CFArray)
    let openResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else {
      onLog?("Could not open the USB HID manager (IOKit error \(openResult))")
      return false
    }
    manager = m
    IOHIDManagerRegisterDeviceMatchingCallback(
      m, hidDeviceMatchingCallback,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    IOHIDManagerRegisterDeviceRemovalCallback(
      m, hidDeviceRemovalCallback,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    IOHIDManagerRegisterInputReportCallback(
      m, hidManagerReportCallback,
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    IOHIDManagerSetDispatchQueue(m, queue)
    IOHIDManagerActivate(m)
    // CopyDevices is only an initial snapshot. The matching callback keeps
    // USB hot-plug working while the driver is already running.
    let devices =
      (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.sorted {
        self.locationID(for: $0) < self.locationID(for: $1)
      } ?? []
    guard !devices.isEmpty else {
      onLog?("USB controller not connected; waiting for USB hot-plug")
      return true
    }
    for device in devices { attach(device) }
    return true
  }

  private func attach(_ d: IOHIDDevice) {
    guard manager != nil, !stopping else { return }
    let registryID = registryID(for: d)
    let locationID = locationID(for: d)
    let identifier = usbIdentifier(locationID: locationID, registryID: registryID)
    guard sessions[registryID] == nil,
      !sessions.values.contains(where: { $0.identifier == identifier })
    else { return }

    // Open the bulk command interface only after a HID device is present.
    // Match by USB location so commands never go to a different controller.
    var usbResult: Int32 = 0
    guard
      let commandConnection = NSOUSBOpen(
        UInt16(NSOConstants.vendorID), UInt16(NSOConstants.productID), 1,
        locationID, &usbResult)
    else {
      onLog?(
        "USB command interface (bulk OUT) could not be opened for \(identifier) (stage \(usbResult))"
      )
      return
    }
    let session = Session(
      registryID: registryID, identifier: identifier, commandConnection: commandConnection,
      playerSlot: sessions.count)
    sessions[registryID] = session
    guard initialize(session) else {
      detach(session, notify: false)
      return
    }
    onLog?("USB controller initialized (\(identifier))")
    onConnected?(session.identifier, NSOConstants.controllerName, .usb)
  }

  func performMatching(_ d: IOHIDDevice) {
    attach(d)
  }

  func setPlayerSlot(_ slot: Int, for identifier: String) {
    queue.async { [weak self] in self?.setPlayerSlotOnQueue(slot, for: identifier) }
  }

  private func setPlayerSlotOnQueue(_ slot: Int, for identifier: String) {
    guard let session = sessions.values.first(where: { $0.identifier == identifier }) else {
      return
    }
    session.playerSlot = slot
    let packet = ledCommand(slot: slot, interface: 0)
    guard let connection = session.commandConnection,
      NSOUSBWrite(connection, packet, UInt32(packet.count)) != 0
    else {
      onLog?("USB player LED write failed for \(identifier)")
      return
    }
  }

  private func initialize(_ session: Session) -> Bool {
    guard let connection = session.commandConnection else { return false }
    for packet in [
      NSOConstants.defaultReport,
      ledCommand(slot: session.playerSlot, interface: 0),
    ] {
      if NSOUSBWrite(connection, packet, UInt32(packet.count)) == 0 {
        onLog?("USB bulk initialization write failed")
        return false
      }
    }
    return true
  }

  func sendRumble(_ active: Bool, for identifier: String) {
    queue.async { [weak self] in self?.sendRumbleOnQueue(active, for: identifier) }
  }

  private func sendRumbleOnQueue(_ active: Bool, for identifier: String) {
    guard
      let connection = sessions.values.first(where: { $0.identifier == identifier })?
        .commandConnection
    else { return }
    let packet = command(0x0a, interface: 0, subcommand: 2, value: active ? 1 : 0)
    _ = NSOUSBWrite(connection, packet, UInt32(packet.count))
  }

  func stop() {
    queue.sync { stopOnQueue() }
  }

  private func stopOnQueue() {
    stopping = true
    if let m = manager {
      IOHIDManagerCancel(m)
      IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    manager = nil
    let connectedSessions = Array(sessions.values)
    for session in connectedSessions { detach(session, notify: false) }
    stopping = false
    for session in connectedSessions { onDisconnected?(session.identifier) }
  }

  private func detach(_ session: Session, notify: Bool) {
    guard sessions.removeValue(forKey: session.registryID) != nil else { return }
    if let connection = session.commandConnection {
      NSOUSBClose(connection)
      session.commandConnection = nil
    }
    if notify { onDisconnected?(session.identifier) }
  }

  func handleDeviceRemoval(_ removed: IOHIDDevice?) {
    guard let removed, !stopping else { return }
    let registryID = registryID(for: removed)
    guard let session = sessions[registryID] else { return }
    onLog?("USB controller disconnected (\(session.identifier))")
    // Keep the manager scheduled so this or another controller can attach.
    detach(session, notify: true)
  }

  fileprivate func forwardReport(
    from device: IOHIDDevice, report: UnsafeMutablePointer<UInt8>, count: CFIndex
  ) {
    guard count > 0, count <= Self.maximumInputReportLength else {
      onLog?("Ignored invalid USB input report length \(count)")
      return
    }
    guard let session = sessions[registryID(for: device)] else { return }
    onReport?(
      session.identifier, Array(UnsafeBufferPointer(start: report, count: count)))
  }

  private func locationID(for device: IOHIDDevice) -> UInt32 {
    (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?
      .uint32Value ?? 0
  }

  private func registryID(for device: IOHIDDevice) -> UInt64 {
    var identifier: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &identifier)
    return identifier
  }

  private func usbIdentifier(locationID: UInt32, registryID: UInt64) -> String {
    if locationID != 0 { return String(format: "usb-%08x", locationID) }
    return String(format: "usb-registry-%016llx", registryID)
  }
}

private func hidDeviceMatchingCallback(
  _ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?,
  _ device: IOHIDDevice?
) {
  guard let context, result == kIOReturnSuccess, let device else { return }
  let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
  transport.performMatching(device)
}

private func hidManagerReportCallback(
  _ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?,
  _ type: IOHIDReportType, _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>,
  _ reportLength: CFIndex
) {
  guard let context, result == kIOReturnSuccess, let sender else { return }
  let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
  let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
  transport.forwardReport(from: device, report: report, count: reportLength)
}

private func hidDeviceRemovalCallback(
  _ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?,
  _ device: IOHIDDevice?
) {
  guard let context else { return }
  let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
  transport.handleDeviceRemoval(device)
}

final class BluetoothTransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,
  @unchecked Sendable
{
  private final class Session {
    let peripheral: CBPeripheral
    var name: String
    var notify: CBCharacteristic?
    var command: CBCharacteristic?
    var handshake: CBCharacteristic?
    var initialized = false
    var awaitingInput = false
    var playerSlot = 0
    var timeout: DispatchWorkItem?
    var pendingNotifications = Set<CBUUID>()
    init(_ peripheral: CBPeripheral, name: String) {
      self.peripheral = peripheral
      self.name = name
    }

    var commandWriteType: CBCharacteristicWriteType {
      guard let command else { return .withoutResponse }
      return command.properties.contains(.writeWithoutResponse)
        ? .withoutResponse : .withResponse
    }
  }

  private var central: CBCentralManager!
  private let queue = DispatchQueue(label: "com.nso-gc-driver.bluetooth", qos: .userInitiated)
  private var sessions: [UUID: Session] = [:]
  private var running = false
  private var connectingIDs = Set<UUID>()
  private var scanStop: DispatchWorkItem?
  private var scanRestart: DispatchWorkItem?
  var onReport: ((String, [UInt8]) -> Void)?
  var onConnected: ((String, String, ConnectionKind) -> Void)?
  var onDisconnected: ((String) -> Void)?
  var onLog: ((String) -> Void)?

  func start() {
    queue.async { [weak self] in
      self?.startOnQueue()
    }
  }

  private func startOnQueue() {
    guard !running else { return }
    running = true
    central = CBCentralManager(delegate: self, queue: queue)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard running, central.state == .poweredOn else {
      guard running else { return }
      onLog?("Bluetooth unavailable (state \(central.state.rawValue))")
      return
    }
    // This controller identifies itself in manufacturer data rather than
    // in its advertised GATT services. Filter in didDiscover below; a
    // CoreBluetooth service scan would miss the controller entirely.
    startScan()
    onLog?("Scanning for Nintendo controllers…")
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any],
    rssi _: NSNumber
  ) {
    guard running, sessions[p.identifier] == nil else { return }
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = (p.name?.isEmpty == false ? p.name : advertisedName) ?? ""
    let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let matchesService = advertised.contains(CBUUID(string: "0012"))
    let matchesManufacturer = matchesNSOManufacturerData(advertisementData)
    // Names are optional and generic names are not useful identifiers.
    // Nintendo's manufacturer data carries the same vendor/product pair
    // as USB (057e:2073). Do not use CoreBluetooth's remembered-peripheral
    // retrieval path: it does not provide working reconnection on macOS.
    guard matchesManufacturer || matchesService else {
      return
    }
    // Do not initiate the link from inside didDiscover. On macOS this can
    // leave a connectable wake advertisement stuck in CoreBluetooth's
    // pending queue while the scanner callback is still active.
    queue.async { [weak self, p] in
      guard let self else { return }
      self.connect(p, name: name)
    }
  }

  private func connect(_ p: CBPeripheral, name: String?) {
    guard running, sessions[p.identifier] == nil, !connectingIDs.contains(p.identifier) else {
      return
    }
    connectingIDs.insert(p.identifier)
    scanStop?.cancel()
    scanRestart?.cancel()
    // Stop scanning only after didDiscover has returned. Initiating the
    // connection from inside the scan callback can leave CoreBluetooth's
    // connect request pending on macOS.
    central.stopScan()
    // CoreBluetooth often reports the controller's generic BLE local name
    // (for example, "DeviceName"). Use the product name in the UI instead.
    let session = Session(p, name: NSOConstants.controllerName)
    sessions[p.identifier] = session
    p.delegate = self
    onLog?(
      "Found BLE controller candidate \(session.name) (\(p.identifier.uuidString)); testing handshake"
    )
    // Waking from low power can take much longer than the initial pairing.
    // A controller that is waking from sleep can take longer than a
    // normal BLE connection to become connectable.
    scheduleAttemptTimeout(for: session, seconds: 30, reason: "BLE connection timed out")
    central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    onLog?("BLE connection request submitted (peripheral state \(p.state.rawValue))")
  }

  func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
    guard let session = sessions[p.identifier] else { return }
    connectingIDs.remove(p.identifier)
    central.stopScan()
    onLog?("Bluetooth connected: \(session.name)")
    scheduleAttemptTimeout(
      for: session, seconds: 5, reason: "controller characteristics were not found")
    p.discoverServices(nil)
    startScan()
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?
  ) {
    connectingIDs.remove(p.identifier)
    if let session = sessions.removeValue(forKey: p.identifier) { session.timeout?.cancel() }
    let detail =
      error.map {
        let nsError = $0 as NSError
        return ": \(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
      } ?? ""
    onLog?("Bluetooth connection failed\(detail); continuing controller search")
    startScan()
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?
  ) {
    connectingIDs.remove(p.identifier)
    guard let session = sessions.removeValue(forKey: p.identifier) else { return }
    session.timeout?.cancel()
    if let error {
      let nsError = error as NSError
      onLog?(
        "Bluetooth disconnected: \(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
      )
    }
    if session.initialized { onDisconnected?(id(for: p)) }
    startScan()
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let session = sessions[p.identifier] else { return }
    if error != nil || p.services?.isEmpty != false {
      reject(session, reason: "service discovery failed")
      return
    }
    for service in p.services ?? [] {
      p.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(
    _ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let session = sessions[p.identifier] else { return }
    if error != nil {
      reject(session, reason: "characteristic discovery failed")
      return
    }
    for c in service.characteristics ?? [] {
      if c.properties.contains(.notify) {
        // Prefer the GameCube input report over command-response or
        // auxiliary notifications.
        if session.notify == nil || c.uuid == NSOConstants.bleInputCharacteristic {
          session.notify = c
        }
        session.pendingNotifications.insert(c.uuid)
        p.setNotifyValue(true, for: c)
      }
      if c.properties.contains(.writeWithoutResponse) || c.properties.contains(.write) {
        let isBasicCommand = c.uuid == NSOConstants.bleBasicCommandCharacteristic
        let isGCCommand = c.uuid == NSOConstants.bleCommandCharacteristic
        // The working NSO initialization sequence writes commands to
        // handle 0x0014. Use the 0x0016 GC command channel only when
        // the basic command characteristic is unavailable.
        if session.handshake == nil || isBasicCommand {
          session.handshake = c
        }
        if isBasicCommand || (session.command == nil && isGCCommand)
          || session.command == nil
        {
          session.command = c
        }
      }
    }
    beginInitializationIfReady(session)
  }

  func peripheral(
    _ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let session = sessions[p.identifier] else { return }
    if let error {
      reject(session, reason: "notification setup failed: \(error.localizedDescription)")
      return
    }
    session.pendingNotifications.remove(characteristic.uuid)
    beginInitializationIfReady(session)
  }

  private func beginInitializationIfReady(_ session: Session) {
    guard let command = session.command, let notify = session.notify, !session.initialized,
      session.pendingNotifications.isEmpty
    else { return }
    _ = notify
    onLog?(
      "BLE report channels ready: input \(notify.uuid.uuidString), command \(command.uuid.uuidString)"
    )
    session.initialized = true
    session.awaitingInput = true
    let handshake = session.handshake ?? command
    let handshakeType: CBCharacteristicWriteType =
      handshake.properties.contains(.write) ? .withResponse : .withoutResponse
    session.peripheral.writeValue(
      Data(NSOConstants.bleHandshake), for: handshake, type: handshakeType)
    session.peripheral.writeValue(
      Data(NSOConstants.defaultReport), for: command, type: session.commandWriteType)
    session.peripheral.writeValue(
      Data(ledCommand(slot: session.playerSlot, interface: 1)), for: command,
      type: session.commandWriteType)
    session.peripheral.writeValue(
      Data(NSOConstants.inputMode), for: handshake, type: handshakeType)
    scheduleAttemptTimeout(
      for: session, seconds: 5,
      reason: "BLE device did not respond as an NSO GameCube controller")
  }

  func peripheral(
    _ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let session = sessions[p.identifier], error == nil,
      let input = session.notify, characteristic.uuid == input.uuid
    else { return }
    if let data = characteristic.value {
      if session.awaitingInput {
        session.awaitingInput = false
        session.timeout?.cancel()
        session.timeout = nil
        onConnected?(id(for: p), session.name, .bluetooth)
        onLog?("BLE controller initialized (player \(session.playerSlot + 1))")
        // Once input is flowing, switch broad discovery to a short
        // duty cycle so scanning does not continuously contend with
        // latency-sensitive controller notifications.
        startScan()
      }
      onReport?(id(for: p), Array(data))
    }
  }

  func setPlayerSlot(_ slot: Int, for identifier: String) {
    queue.async { [weak self] in
      self?.setPlayerSlotOnQueue(slot, for: identifier)
    }
  }

  private func setPlayerSlotOnQueue(_ slot: Int, for identifier: String) {
    guard let uuid = UUID(uuidString: identifier), let session = sessions[uuid] else { return }
    session.playerSlot = slot
    if let command = session.command {
      let packet = ledCommand(slot: slot, interface: 1)
      session.peripheral.writeValue(
        Data(packet), for: command, type: session.commandWriteType)
    }
  }

  func sendRumble(_ active: Bool, for identifier: String) {
    queue.async { [weak self] in
      self?.sendRumbleOnQueue(active, for: identifier)
    }
  }

  private func sendRumbleOnQueue(_ active: Bool, for identifier: String) {
    guard let uuid = UUID(uuidString: identifier), let session = sessions[uuid],
      let c = session.command
    else { return }
    let packet: [UInt8] = [
      0x0a, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, active ? 1 : 0, 0x00, 0x00, 0x00,
    ]
    session.peripheral.writeValue(
      Data(packet), for: c,
      type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue()
    }
  }

  private func stopOnQueue() {
    running = false
    scanStop?.cancel()
    scanRestart?.cancel()
    scanStop = nil
    scanRestart = nil
    for session in sessions.values {
      session.timeout?.cancel()
      central?.cancelPeripheralConnection(session.peripheral)
    }
    central?.stopScan()
    sessions.removeAll()
    connectingIDs.removeAll()
    central?.delegate = nil
    central = nil
  }

  private func id(for peripheral: CBPeripheral) -> String {
    "ble-\(peripheral.identifier.uuidString)"
  }
  private func matchesNSOManufacturerData(_ advertisementData: [String: Any]) -> Bool {
    if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
      return matchesNSOManufacturerBytes(Array(data), includesCompanyID: true)
    }
    if let entries = advertisementData[CBAdvertisementDataManufacturerDataKey]
      as? [NSNumber: Data]
    {
      return entries.contains { company, data in
        company.intValue == NSOConstants.bluetoothCompanyID
          && matchesNSOManufacturerBytes(Array(data), includesCompanyID: false)
      }
    }
    return false
  }
  private func matchesNSOManufacturerBytes(_ bytes: [UInt8], includesCompanyID: Bool) -> Bool {
    let offset = includesCompanyID ? 2 : 0
    guard bytes.count >= offset + 7 else { return false }
    if includesCompanyID && (bytes[0] != 0x53 || bytes[1] != 0x05) { return false }
    let vendorLE = Int(bytes[offset + 3]) | Int(bytes[offset + 4]) << 8
    let productLE = Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8
    let vendorBE = Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
    let productBE = Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6])
    return (vendorLE == NSOConstants.vendorID && productLE == NSOConstants.productID)
      || (vendorBE == NSOConstants.vendorID && productBE == NSOConstants.productID)
  }
  private func scheduleAttemptTimeout(for session: Session, seconds: Double, reason: String) {
    session.timeout?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak session] in
      guard let self, let session, self.running,
        self.sessions[session.peripheral.identifier] != nil
      else { return }
      self.reject(session, reason: reason)
    }
    session.timeout = timeout
    queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
  }
  private func reject(_ session: Session, reason: String) {
    guard running else { return }
    onLog?("BLE candidate rejected: \(reason)")
    session.timeout?.cancel()
    sessions.removeValue(forKey: session.peripheral.identifier)
    connectingIDs.remove(session.peripheral.identifier)
    central.cancelPeripheralConnection(session.peripheral)
    startScan()
  }
  private func startScan() {
    guard running, central.state == .poweredOn else { return }
    scanStop?.cancel()
    scanRestart?.cancel()
    scanStop = nil
    scanRestart = nil
    let connectedCount = sessions.values.filter(\.initialized).count
    if connectedCount >= 4 {
      central.stopScan()
      return
    }
    central.scanForPeripherals(
      withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    guard connectedCount > 0 else { return }

    let stop = DispatchWorkItem { [weak self] in
      guard let self, self.running else { return }
      self.central.stopScan()
      let restart = DispatchWorkItem { [weak self] in self?.startScan() }
      self.scanRestart = restart
      self.queue.asyncAfter(deadline: .now() + 8.5, execute: restart)
    }
    scanStop = stop
    queue.asyncAfter(deadline: .now() + 1.5, execute: stop)
  }
}
