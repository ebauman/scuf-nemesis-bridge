import CoreHID
import Foundation
import IOKit
import IOUSBHost

// SCUF Bridge
//
// Reads Xbox 360-format input reports from the SCUF's XInput interface
// (USB interface 0, class 0xFF / subclass 0x5D / protocol 0x01), which macOS
// has no driver for, and re-publishes them as a standard HID gamepad that
// Wine-based layers and native games can see.
//
// Usage: scuf-bridge [--dry-run]
//   --dry-run  translate and print reports without creating the virtual device
//              (works without the HID virtual device entitlement)

setvbuf(stdout, nil, _IOLBF, 0)

let dryRun = CommandLine.arguments.contains("--dry-run")

// MARK: - Virtual gamepad report descriptor

// 13-byte input report, no report ID:
//   LX LY RX RY  Int16 each (HID convention: Y positive = down)
//   LT RT        UInt8 each
//   hat          low nibble, 0-7 clockwise from up, 8 = centered
//   buttons      11 bits: A B X Y LB RB Back Start LS RS Guide
let reportDescriptor: [UInt8] = [
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x05,             // Usage (Gamepad)
    0xA1, 0x01,             // Collection (Application)
    0xA1, 0x00,             //   Collection (Physical)

    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x09, 0x33,             //     Usage (Rx)
    0x09, 0x34,             //     Usage (Ry)
    0x16, 0x00, 0x80,       //     Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,       //     Logical Maximum (32767)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x04,             //     Report Count (4)
    0x81, 0x02,             //     Input (Data, Var, Abs)

    0x09, 0x32,             //     Usage (Z)
    0x09, 0x35,             //     Usage (Rz)
    0x15, 0x00,             //     Logical Minimum (0)
    0x26, 0xFF, 0x00,       //     Logical Maximum (255)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x02,             //     Input (Data, Var, Abs)

    0x09, 0x39,             //     Usage (Hat Switch)
    0x15, 0x00,             //     Logical Minimum (0)
    0x25, 0x07,             //     Logical Maximum (7)
    0x35, 0x00,             //     Physical Minimum (0)
    0x46, 0x3B, 0x01,       //     Physical Maximum (315)
    0x65, 0x14,             //     Unit (Degrees)
    0x75, 0x04,             //     Report Size (4)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x42,             //     Input (Data, Var, Abs, Null State)
    0x65, 0x00,             //     Unit (None)
    0x75, 0x04,             //     Report Size (4)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x03,             //     Input (Const) - padding

    0x05, 0x09,             //     Usage Page (Button)
    0x19, 0x01,             //     Usage Minimum (1)
    0x29, 0x0B,             //     Usage Maximum (11)
    0x15, 0x00,             //     Logical Minimum (0)
    0x25, 0x01,             //     Logical Maximum (1)
    0x75, 0x01,             //     Report Size (1)
    0x95, 0x0B,             //     Report Count (11)
    0x81, 0x02,             //     Input (Data, Var, Abs)
    0x75, 0x05,             //     Report Size (5)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x03,             //     Input (Const) - padding

    0xC0,                   //   End Collection
    0xC0,                   // End Collection
]

// MARK: - Xbox 360 report translation

struct GamepadState: Equatable {
    var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    var lt: UInt8 = 0, rt: UInt8 = 0
    var hat: UInt8 = 8
    var buttons: UInt16 = 0

    var report: Data {
        var d = Data(capacity: 13)
        for axis in [lx, ly, rx, ry] {
            let v = UInt16(bitPattern: axis)
            d.append(UInt8(v & 0xFF))
            d.append(UInt8(v >> 8))
        }
        d.append(lt)
        d.append(rt)
        d.append(hat & 0x0F)
        d.append(UInt8(buttons & 0xFF))
        d.append(UInt8(buttons >> 8))
        return d
    }
}

// Xbox 360 sticks report up as positive; HID gamepads report down as positive
func invert(_ v: Int16) -> Int16 { v == .min ? .max : -v }

// 360 report: 00 14, d-pad/menu bits, face/shoulder bits, LT, RT, LX LY RX RY
func translate(_ r: [UInt8]) -> GamepadState? {
    guard r.count >= 14, r[0] == 0x00, r[1] == 0x14 else { return nil }

    func axis(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(r[i]) | UInt16(r[i + 1]) << 8) }

    let up = r[2] & 0x01 != 0, down = r[2] & 0x02 != 0
    let left = r[2] & 0x04 != 0, right = r[2] & 0x08 != 0

    let hat: UInt8
    switch (up, down, left, right) {
    case (true, false, false, false): hat = 0
    case (true, false, false, true): hat = 1
    case (false, false, false, true): hat = 2
    case (false, true, false, true): hat = 3
    case (false, true, false, false): hat = 4
    case (false, true, true, false): hat = 5
    case (false, false, true, false): hat = 6
    case (true, false, true, false): hat = 7
    default: hat = 8
    }

    // Output bit order: A B X Y LB RB Back Start LS RS Guide
    let mapping: [(Int, UInt8)] = [
        (3, 0x10), (3, 0x20), (3, 0x40), (3, 0x80),     // A B X Y
        (3, 0x01), (3, 0x02),                           // LB RB
        (2, 0x20), (2, 0x10),                           // Back Start
        (2, 0x40), (2, 0x80),                           // LS RS
        (3, 0x04),                                      // Guide
    ]
    var buttons: UInt16 = 0
    for (bit, (byte, mask)) in mapping.enumerated() where r[byte] & mask != 0 {
        buttons |= 1 << bit
    }

    return GamepadState(
        lx: axis(6), ly: invert(axis(8)),
        rx: axis(10), ry: invert(axis(12)),
        lt: r[4], rt: r[5],
        hat: hat,
        buttons: buttons
    )
}

// MARK: - XInput interface reader

final class XInputReader {
    let interface: IOUSBHostInterface
    let pipe: IOUSBHostPipe
    let buffer: NSMutableData

    init() throws {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: 0x1B1C,
            productID: 0x3A3F,
            bcdDevice: nil,
            interfaceNumber: 0,
            configurationValue: 1, // required alongside interfaceNumber for interface matching
            interfaceClass: nil,
            interfaceSubclass: nil,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        ).takeRetainedValue()

        // IOServiceGetMatchingService consumes one reference to the dictionary
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw NSError(domain: "ScufBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SCUF XInput interface not found. Is the controller connected?"
            ])
        }

        interface = try IOUSBHostInterface(
            __ioService: service,
            options: [],
            queue: nil,
            interestHandler: nil
        )

        // Find the interrupt IN endpoint
        var inAddress: UInt8?
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let endpoint = IOUSBGetNextEndpointDescriptor(
            interface.configurationDescriptor,
            interface.interfaceDescriptor,
            current
        ) {
            let address = IOUSBGetEndpointAddress(endpoint)
            if address & 0x80 != 0,
               IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointDescriptorTransferTypeInterrupt) {
                inAddress = address
                break
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress else {
            throw NSError(domain: "ScufBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No interrupt IN endpoint on the XInput interface"
            ])
        }

        pipe = try interface.copyPipe(withAddress: Int(inAddress))
        // IO-mapped buffer from the framework; a plain NSMutableData overruns
        buffer = try interface.ioData(withCapacity: 64)
    }

    /// Blocks until the next report arrives.
    func read() throws -> [UInt8] {
        var transferred = 0
        do {
            // Timeout must be 0 for interrupt pipes
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
        } catch {
            // A failed transfer stalls the pipe; clear it or every later read fails too
            try? pipe.clearStall()
            throw error
        }
        return Array(UnsafeBufferPointer(
            start: buffer.bytes.assumingMemoryBound(to: UInt8.self),
            count: transferred
        ))
    }
}

// MARK: - Virtual device

struct NoopDelegate: HIDVirtualDeviceDelegate {
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {}

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        // Hosts may poll the current input state; an idle report is a safe answer
        GamepadState().report
    }
}

// MARK: - Main

let reader: XInputReader
do {
    reader = try XInputReader()
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
print("Opened SCUF XInput interface.")

var virtualDevice: HIDVirtualDevice?
if !dryRun {
    let properties = HIDVirtualDevice.Properties(
        descriptor: Data(reportDescriptor),
        vendorID: 0x1B1C,
        productID: 0xFF3F, // distinct from the real controller's 0x3A3F
        transport: .virtual,
        product: "SCUF Bridge Gamepad",
        manufacturer: "SCUF Bridge"
    )
    guard let device = HIDVirtualDevice(properties: properties) else {
        print("""
        Error: could not create the virtual gamepad.
        This needs the com.apple.developer.hid.virtual.device entitlement and a
        provisioning profile that grants it. Run with --dry-run to test the
        translation without it.
        """)
        exit(1)
    }
    await device.activate(delegate: NoopDelegate())
    virtualDevice = device
    print("Virtual gamepad active: \(device)")
}

// Reads block, so they run on their own thread and feed an ordered stream
let reports = AsyncStream<[UInt8]> { continuation in
    let thread = Thread {
        var consecutiveErrors = 0
        while true {
            do {
                continuation.yield(try reader.read())
                consecutiveErrors = 0
            } catch {
                consecutiveErrors += 1
                // The first read after opening can overrun once; persistent
                // failures mean the controller went away
                if consecutiveErrors >= 20 {
                    print("Error: controller stopped responding (\(error.localizedDescription))")
                    exit(2)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    thread.qualityOfService = .userInteractive
    thread.start()
}

print(dryRun ? "DRY RUN: printing translated state. CTRL+C to stop." : "Bridging. CTRL+C to stop.")

var last: GamepadState?
for await raw in reports {
    guard let state = translate(raw), state != last else { continue }
    last = state

    if let virtualDevice {
        do {
            try await virtualDevice.dispatchInputReport(data: state.report, timestamp: .now)
        } catch {
            print("Dispatch failed: \(error)")
        }
    } else {
        let hex = state.report.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("\(hex)  L=(\(state.lx),\(state.ly)) R=(\(state.rx),\(state.ry)) LT=\(state.lt) RT=\(state.rt) hat=\(state.hat) buttons=0b\(String(state.buttons, radix: 2))")
    }
}
