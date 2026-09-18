import Darwin
import Foundation
@preconcurrency import IOKit.hid
@preconcurrency import IOKit.hidsystem

/// Publishes the decoded controller as a normal macOS HID gamepad.
final class VirtualGamepad: @unchecked Sendable {
    private let identifier: String
    private var device: IOHIDUserDevice?
    private let queue: DispatchQueue
    private var lastReport = [UInt8](repeating: 0, count: 64)
    private var rumbleActive = false
    var onRumble: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    init(identifier: String) {
        self.identifier = identifier
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

    private static var neutralReport: [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = inputReportID
        report[1] = 1  // No battery.
        putInt16(.min, at: 15, in: &report)
        putInt16(.min, at: 17, in: &report)
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

    private static let reportDescriptor: [UInt8] = [
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

    @discardableResult
    func start() -> Bool {
        queue.sync { startOnQueue() }
    }

    private func startOnQueue() -> Bool {
        guard device == nil else { return true }
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(Self.reportDescriptor),
            // SDL combines manufacturer and product. Keeping the manufacturer
            // as the shared "NSO" prefix lets its de-duplication return the
            // exact product name below.
            kIOHIDManufacturerKey as String: "NSO",
            kIOHIDProductKey as String: "NSO GameCube Virtual Gamepad",
            // A unique serial prevents HID/SDL clients from folding multiple
            // physical controllers into one logical device.
            kIOHIDSerialNumberKey as String: "NSOGCDriver-\(identifier)",
            kIOHIDVendorIDKey as String: Self.virtualVendorID,
            kIOHIDProductIDKey as String: Self.virtualProductID,
            kIOHIDVersionNumberKey as String: 0x0100,
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
        IOHIDUserDeviceSetDispatchQueue(virtual, queue)
        device = virtual
        IOHIDUserDeviceActivate(virtual)
        lastReport = Self.neutralReport
        send(Self.neutralReport, to: virtual)
        onLog?("Virtual HID gamepad published for \(identifier) with rumble")
        return true
    }

    func update(_ state: ControllerState) {
        queue.async { [weak self] in
            self?.updateOnQueue(state)
        }
    }

    private func updateOnQueue(_ state: ControllerState) {
        guard let device else { return }
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
