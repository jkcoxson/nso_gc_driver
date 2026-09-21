import Darwin
import Foundation
@preconcurrency import IOKit.hid
@preconcurrency import IOKit.hidsystem

enum VirtualGamepadMode: String, CaseIterable, Identifiable {
    case dolphinSInput
    case standardHID

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dolphinSInput: return "Dolphin / SInput"
        case .standardHID: return "Compatibility"
        }
    }

    var helpText: String {
        switch self {
        case .dolphinSInput:
            return "Uses SDL's SInput protocol so current Dolphin builds can send rumble. Older SDL 2 apps, including Ryujinx, cannot decode this report format."
        case .standardHID:
            return "Uses conventional HID controls for apps that do not support SInput. Rumble is unavailable in this mode because macOS virtual HID devices do not provide an Apple Force Feedback plug-in."
        }
    }
}

/// Publishes the decoded controller as a normal macOS HID gamepad.
final class VirtualGamepad: @unchecked Sendable {
    private let identifier: String
    private let mode: VirtualGamepadMode
    private var device: IOHIDUserDevice?
    private let queue: DispatchQueue
    private var lastReport: [UInt8] = []
    private var rumbleActive = false
    var onRumble: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    init(identifier: String, mode: VirtualGamepadMode) {
        self.identifier = identifier
        self.mode = mode
        queue = DispatchQueue(label: "com.nso-gc-driver.virtual-gamepad.\(identifier)")
    }

    // Dolphin uses SDL on macOS. SDL's generic IOKit backend only exposes
    // rumble for devices backed by an Apple ForceFeedback plug-in; an
    // IOHIDUserDevice output report alone does not create one. The native
    // 057e:2073 identity is also unsuitable here because SDL reserves it for
    // the physical Switch 2 GameCube controller and expects a bulk USB
    // interface that a virtual HID device cannot provide.
    //
    // Use SDL's generic SInput protocol at the virtual boundary. This remains
    // a normal Apple IOHIDUserDevice and adds no library dependency. SInput
    // gives SDL an explicit rumble capability while preserving the USB product
    // name, so Dolphin displays "NSO GameCube Virtual Gamepad".
    private static let virtualVendorID = 0x2e8a
    private static let virtualProductID = 0x10c6
    private static let inputReportID: UInt8 = 1
    private static let commandResponseReportID: UInt8 = 2
    private static let outputReportID: UInt32 = 3
    private static let reportLength = 64

    // Compatibility mode deliberately uses the identity and element ordering
    // of a controller already present in SDL 2's macOS mapping database. Apps
    // that accept only SDL_GameController devices otherwise filter out a
    // standards-compliant HID descriptor with a new VID/PID. Unlike SDL's
    // original GameCube profile, this mapping exposes all four L/R and ZL/ZR
    // actions as well as Home and Capture.
    private static let standardVendorID = 0x05ac
    private static let standardProductID = 0x061a
    private static let standardVersion = 0x0202
    private static let standardReportID: UInt8 = 1

    /// Counts the virtual devices by asking the HID registry, rather than
    /// assuming a successful publisher call made them visible to clients.
    static func visibleDeviceCount(mode: VirtualGamepadMode) -> Int {
        let identity = identity(for: mode)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [
                kIOHIDVendorIDKey as String: identity.vendor,
                kIOHIDProductIDKey as String: identity.product,
            ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return 0
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
    }

    private static var neutralReport: [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = inputReportID
        report[1] = 1  // No battery.
        putInt16(.min, at: 15, in: &report)
        putInt16(.min, at: 17, in: &report)
        return report
    }

    private static var standardNeutralReport: [UInt8] {
        var report = [UInt8](repeating: 0, count: 16)
        report[0] = standardReportID
        // SDL's IOKit backend scales the full signed logical range directly.
        putInt16(0, at: 3, in: &report)
        putInt16(0, at: 5, in: &report)
        putInt16(0, at: 7, in: &report)
        putInt16(0, at: 9, in: &report)
        putInt16(.min, at: 11, in: &report)
        putInt16(.min, at: 13, in: &report)
        report[15] = 8  // Hat switch null value (centered).
        return report
    }

    private var featuresResponse: [UInt8] {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = Self.commandResponseReportID
        report[1] = 2  // SInput features command.

        // The feature block begins at byte 2.
        report[2] = 1  // Protocol version 1, little endian.
        report[3] = 0
        report[4] = 0xF1  // Rumble, both sticks, and both analog triggers.
        report[5] = 0
        report[6] = 11  // SDL_GAMEPAD_TYPE_GAMECUBE.
        report[7] = 0x40  // AXBY face-button labels, no sub-product.
        report[8] = 0x40  // 8,000 microsecond polling interval.
        report[9] = 0x1F
        report[10] = 8  // Nominal accelerometer range (feature disabled).
        report[12] = 0xD0  // Nominal 2,000 dps gyro range (feature disabled).
        report[13] = 0x07

        // Four face buttons, D-pad, L/R, ZL/Z, Start, Back, Home, Capture.
        report[14] = 0xFF
        report[15] = 0x3C
        report[16] = 0x0F
        report[17] = 0

        // SInput has its own six-byte identity in addition to the IOHID serial.
        // Derive it from the physical controller ID so SDL does not merge peers.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        for index in 0..<6 {
            report[20 + index] = UInt8(truncatingIfNeeded: hash >> (index * 8))
        }
        return report
    }

    private static let sinputReportDescriptor: [UInt8] = [
        0x05, 0x01,  // Usage Page (Generic Desktop)
        0x09, 0x05,  // Usage (Game Pad)
        0xA1, 0x01,  // Collection (Application)
        0x06, 0x00, 0xFF,  // Vendor-defined SInput reports
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,

        0x09, 0x01,
        0x85, inputReportID,
        0x95, 0x3F,  // 63 payload bytes + report ID = 64
        0x81, 0x02,

        0x09, 0x02,
        0x85, commandResponseReportID,
        0x95, 0x3F,  // 63 payload bytes + report ID = 64
        0x81, 0x02,

        0x09, 0x03,
        0x85, UInt8(outputReportID),
        0x95, 0x2F,  // 47 payload bytes + report ID = 48
        0x91, 0x02,
        0xC0,
    ]

    // A conventional HID gamepad for SDL 2 consumers. Element usages are
    // chosen so SDL's sorted IOKit axes match the selected database entry:
    // X/Y, C-stick X/Y, right analog trigger, left analog trigger.
    private static let standardReportDescriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x05,        // Usage (Game Pad)
        0xA1, 0x01,        // Collection (Application)
        0x85, standardReportID,

        0x05, 0x09,        // Usage Page (Button)
        0x19, 0x01,        // Usage Minimum (Button 1)
        0x29, 0x10,        // Usage Maximum (Button 16)
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x10,
        0x81, 0x02,        // Input (Data, Variable, Absolute)

        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x16, 0x00, 0x80,  // Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,  // Logical Maximum (32767)
        0x75, 0x10,
        0x95, 0x06,
        0x09, 0x30,        // X
        0x09, 0x31,        // Y
        0x09, 0x32,        // Z (C-stick X)
        0x09, 0x33,        // Rx (C-stick Y)
        0x09, 0x34,        // Ry (R analog)
        0x09, 0x35,        // Rz (L analog)
        0x81, 0x02,

        0x09, 0x39,        // Hat switch
        0x15, 0x00,
        0x25, 0x07,
        0x35, 0x00,
        0x46, 0x3B, 0x01,  // Physical Maximum (315 degrees)
        0x65, 0x14,
        0x75, 0x08,
        0x95, 0x01,
        0x81, 0x42,        // Input (Data, Variable, Absolute, Null State)
        0xC0,
    ]

    private static func identity(for mode: VirtualGamepadMode) -> (vendor: Int, product: Int, version: Int) {
        switch mode {
        case .dolphinSInput:
            return (virtualVendorID, virtualProductID, 0x0100)
        case .standardHID:
            return (standardVendorID, standardProductID, standardVersion)
        }
    }

    @discardableResult
    func start() -> Bool {
        queue.sync { startOnQueue() }
    }

    private func startOnQueue() -> Bool {
        guard device == nil else { return true }
        let identity = Self.identity(for: mode)
        let descriptor = mode == .dolphinSInput
            ? Self.sinputReportDescriptor : Self.standardReportDescriptor
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(descriptor),
            // SDL combines manufacturer and product. Keeping the manufacturer
            // as the shared "NSO" prefix lets its de-duplication return the
            // exact product name below.
            kIOHIDManufacturerKey as String: "NSO",
            kIOHIDProductKey as String: "NSO GameCube Virtual Gamepad",
            // A unique serial prevents HID/SDL clients from folding multiple
            // physical controllers into one logical device.
            kIOHIDSerialNumberKey as String: "NSOGCDriver-\(identifier)",
            kIOHIDVendorIDKey as String: identity.vendor,
            kIOHIDProductIDKey as String: identity.product,
            kIOHIDVersionNumberKey as String: identity.version,
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey as String: kHIDUsage_GD_GamePad,
            kIOHIDTransportKey as String: "Virtual",
        ]
        guard
            let virtual = IOHIDUserDeviceCreateWithProperties(
                kCFAllocatorDefault, properties as CFDictionary, 0)
        else {
            onLog?(
                "Could not create virtual HID gamepad (virtual-device entitlement may be unavailable)"
            )
            return false
        }

        if mode == .dolphinSInput {
            IOHIDUserDeviceRegisterSetReportBlock(virtual) {
                [weak self] _, reportID, report, length in
                guard let self else { return kIOReturnNotOpen }
                guard reportID == Self.outputReportID else { return kIOReturnUnsupported }
                guard length > 0, length <= Self.reportLength else { return kIOReturnBadArgument }

                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                let payload = bytes.first == UInt8(reportID) ? Array(bytes.dropFirst()) : bytes
                guard let command = payload.first else { return kIOReturnBadArgument }

                switch command {
                case 1:  // Haptic command.
                    guard payload.count >= 5, payload[1] == 2 else {
                        return kIOReturnBadArgument
                    }
                    self.setRumble(payload[2] != 0 || payload[4] != 0)
                case 2:  // Features query.
                    // Reply after this SetReport completes so SDL's following read
                    // receives a complete command response.
                    self.queue.async { [weak self] in
                        guard let self, self.device != nil else { return }
                        self.send(self.featuresResponse, to: virtual)
                    }
                default:
                    break
                }
                return kIOReturnSuccess
            }
        }
        IOHIDUserDeviceSetDispatchQueue(virtual, queue)
        device = virtual
        IOHIDUserDeviceActivate(virtual)
        let neutral = mode == .dolphinSInput ? Self.neutralReport : Self.standardNeutralReport
        lastReport = neutral
        send(neutral, to: virtual)
        onLog?("Virtual HID gamepad published for \(identifier) in \(mode.title) mode")
        return true
    }

    func update(_ state: ControllerState) {
        queue.async { [weak self] in
            self?.updateOnQueue(state)
        }
    }

    private func updateOnQueue(_ state: ControllerState) {
        guard let device else { return }
        if mode == .standardHID {
            updateStandardHID(state, device: device)
            return
        }
        var report = Self.neutralReport
        let buttons = state.buttons

        if let battery = state.battery {
            if battery.isCharging {
                report[1] = 2  // Charging.
            } else if battery.hasExternalPower && battery.level == 9 {
                report[1] = 3  // Charged.
            } else {
                report[1] = 4  // On battery.
            }
            report[2] = UInt8(battery.percentage)
        }

        // SInput's first button byte: east, south, north, west, then D-pad.
        // For a GameCube face layout those positions are X, A, Y, and B.
        if buttons["X"] == true { report[3] |= 0x01 }
        if buttons["A"] == true { report[3] |= 0x02 }
        if buttons["Y"] == true { report[3] |= 0x04 }
        if buttons["B"] == true { report[3] |= 0x08 }
        if buttons["Dpad_Up"] == true { report[3] |= 0x10 }
        if buttons["Dpad_Down"] == true { report[3] |= 0x20 }
        if buttons["Dpad_Left"] == true { report[3] |= 0x40 }
        if buttons["Dpad_Right"] == true { report[3] |= 0x80 }

        if buttons["L"] == true { report[4] |= 0x04 }
        if buttons["R"] == true { report[4] |= 0x08 }
        if buttons["ZL"] == true { report[4] |= 0x10 }
        if buttons["Z"] == true { report[4] |= 0x20 }

        if buttons["Start"] == true { report[5] |= 0x01 }
        if buttons["Home"] == true { report[5] |= 0x04 }
        if buttons["Capture"] == true { report[5] |= 0x08 }

        Self.putInt16(axis(state.leftX), at: 7, in: &report)
        Self.putInt16(axis(state.leftY), at: 9, in: &report)
        Self.putInt16(axis(state.rightX), at: 11, in: &report)
        Self.putInt16(axis(state.rightY), at: 13, in: &report)
        Self.putInt16(trigger(state.leftTrigger), at: 15, in: &report)
        Self.putInt16(trigger(state.rightTrigger), at: 17, in: &report)

        guard report != lastReport else { return }
        lastReport = report
        send(report, to: device)
    }

    private func updateStandardHID(_ state: ControllerState, device: IOHIDUserDevice) {
        var report = Self.standardNeutralReport
        let buttons = state.buttons

        // SDL mapping: A, B, X/Y at buttons 4/5, shoulders at 7/8,
        // Capture/Start at 11/12, and Home at 16. The physical controller's
        // R/ZR and L/ZL reports are opposite this mapping's shoulder/trigger
        // convention, so route the Z buttons to shoulders and L/R to triggers.
        if buttons["A"] == true { report[1] |= 0x01 }
        if buttons["B"] == true { report[1] |= 0x02 }
        if buttons["X"] == true { report[1] |= 0x08 }
        if buttons["Y"] == true { report[1] |= 0x10 }
        if buttons["ZL"] == true { report[1] |= 0x40 }
        if buttons["Z"] == true { report[1] |= 0x80 }
        if buttons["Capture"] == true { report[2] |= 0x04 }
        if buttons["Start"] == true { report[2] |= 0x08 }
        if buttons["Home"] == true { report[2] |= 0x80 }

        Self.putInt16(axis(state.leftX), at: 3, in: &report)
        Self.putInt16(axis(-state.leftY), at: 5, in: &report)
        Self.putInt16(axis(state.rightX), at: 7, in: &report)
        Self.putInt16(axis(-state.rightY), at: 9, in: &report)
        let leftTrigger = buttons["L"] == true ? UInt8.max : state.leftTrigger
        let rightTrigger = buttons["R"] == true ? UInt8.max : state.rightTrigger
        // SDL maps the fifth axis to the right trigger and the sixth to left.
        Self.putInt16(trigger(rightTrigger), at: 11, in: &report)
        Self.putInt16(trigger(leftTrigger), at: 13, in: &report)
        report[15] = hatValue(buttons)

        guard report != lastReport else { return }
        lastReport = report
        send(report, to: device)
    }

    private func hatValue(_ buttons: [String: Bool]) -> UInt8 {
        let up = buttons["Dpad_Up"] == true && buttons["Dpad_Down"] != true
        let down = buttons["Dpad_Down"] == true && buttons["Dpad_Up"] != true
        let left = buttons["Dpad_Left"] == true && buttons["Dpad_Right"] != true
        let right = buttons["Dpad_Right"] == true && buttons["Dpad_Left"] != true
        switch (up, down, left, right) {
        case (true, false, false, false): return 0
        case (true, false, false, true): return 1
        case (false, false, false, true): return 2
        case (false, true, false, true): return 3
        case (false, true, false, false): return 4
        case (false, true, true, false): return 5
        case (false, false, true, false): return 6
        case (true, false, true, false): return 7
        default: return 8
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard let device else { return }
        // Stop the physical controller before its transport is torn down.
        setRumble(false)
        IOHIDUserDeviceCancel(device)
        self.device = nil
        onLog?("Virtual HID gamepad removed for \(identifier)")
    }

    private func send(_ report: [UInt8], to device: IOHIDUserDevice) {
        report.withUnsafeBufferPointer { buffer in
            _ = IOHIDUserDeviceHandleReportWithTimeStamp(
                device, mach_absolute_time(), buffer.baseAddress!, buffer.count)
        }
    }

    private func setRumble(_ active: Bool) {
        guard active != rumbleActive else { return }
        rumbleActive = active
        onRumble?(active)
    }

    private func axis(_ value: Int) -> Int16 {
        let scaled = Int((Double(value) * 32767.0 / 1400.0).rounded())
        return Int16(max(Int(Int16.min), min(Int(Int16.max), scaled)))
    }

    private func trigger(_ value: UInt8) -> Int16 {
        Int16(Int(value) * 257 + Int(Int16.min))
    }

    private static func putInt16(_ value: Int16, at index: Int, in report: inout [UInt8]) {
        let bits = UInt16(bitPattern: value)
        report[index] = UInt8(truncatingIfNeeded: bits)
        report[index + 1] = UInt8(truncatingIfNeeded: bits >> 8)
    }
}
