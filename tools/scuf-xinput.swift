
import Foundation
import IOKit
import IOUSBHost

// Read-only probe of the SCUF's XInput interface (USB interface 0,
// class 0xFF / subclass 0x5D / protocol 0x01). macOS has no driver for it,
// so we open it from userspace and read its interrupt IN endpoint.
// Nothing is ever written to the controller.

// Line-buffer stdout so output survives CTRL+C and piping to tee
setvbuf(stdout, nil, _IOLBF, 0)

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
    fatalError("XInput interface (interface 0) not found")
}

let interface: IOUSBHostInterface
do {
    interface = try IOUSBHostInterface(
        __ioService: service,
        options: [],
        queue: nil,
        interestHandler: nil
    )
} catch {
    fatalError("Interface open failed: \(error)")
}

let ifaceDesc = interface.interfaceDescriptor
print("Opened interface \(ifaceDesc.pointee.bInterfaceNumber): class 0x\(String(ifaceDesc.pointee.bInterfaceClass, radix: 16)) subclass 0x\(String(ifaceDesc.pointee.bInterfaceSubClass, radix: 16)) protocol 0x\(String(ifaceDesc.pointee.bInterfaceProtocol, radix: 16))")

// Walk the endpoint descriptors and pick the interrupt IN endpoint
var inAddress: UInt8?
var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
while let endpoint = IOUSBGetNextEndpointDescriptor(
    interface.configurationDescriptor,
    ifaceDesc,
    current
) {
    let address = IOUSBGetEndpointAddress(endpoint)
    let type = IOUSBGetEndpointType(endpoint)
    let isIn = address & 0x80 != 0
    print("  Endpoint 0x\(String(address, radix: 16)) \(isIn ? "IN" : "OUT") type \(type) maxPacket \(endpoint.pointee.wMaxPacketSize) interval \(endpoint.pointee.bInterval)")

    if isIn, type == UInt8(kIOUSBEndpointDescriptorTransferTypeInterrupt) {
        inAddress = address
    }

    current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
}

guard let inAddress else {
    fatalError("No interrupt IN endpoint on interface 0")
}

let pipe: IOUSBHostPipe
do {
    pipe = try interface.copyPipe(withAddress: Int(inAddress))
} catch {
    fatalError("Pipe open failed: \(error)")
}

print("\nCAPTURING from endpoint 0x\(String(inAddress, radix: 16)). Press buttons and move sticks. CTRL+C to stop.")

// IO-mapped buffer from the framework; a plain NSMutableData overruns
let buffer: NSMutableData
do {
    buffer = try interface.ioData(withCapacity: 64)
} catch {
    fatalError("Buffer allocation failed: \(error)")
}

// Standard Xbox 360 input report: 00 14, buttons (2 bytes), LT, RT,
// then LX LY RX RY as little-endian Int16
func decodeXbox360(_ r: [UInt8]) -> String? {
    guard r.count >= 14, r[0] == 0x00, r[1] == 0x14 else { return nil }

    let names: [(Int, UInt8, String)] = [
        (2, 0x01, "Up"), (2, 0x02, "Down"), (2, 0x04, "Left"), (2, 0x08, "Right"),
        (2, 0x10, "Start"), (2, 0x20, "Back"), (2, 0x40, "LS"), (2, 0x80, "RS"),
        (3, 0x01, "LB"), (3, 0x02, "RB"), (3, 0x04, "Guide"),
        (3, 0x10, "A"), (3, 0x20, "B"), (3, 0x40, "X"), (3, 0x80, "Y")
    ]
    let pressed = names.filter { r[$0.0] & $0.1 != 0 }.map(\.2)

    func axis(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(r[i]) | UInt16(r[i + 1]) << 8) }

    return "buttons=[\(pressed.joined(separator: " "))] LT=\(r[4]) RT=\(r[5]) " +
        "L=(\(axis(6)),\(axis(8))) R=(\(axis(10)),\(axis(12)))"
}

var last: [UInt8] = []
while true {
    var transferred = 0

    do {
        // Timeout must be 0 for interrupt pipes: blocks until a report arrives
        try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
    } catch {
        let code = UInt32(bitPattern: Int32(truncatingIfNeeded: (error as NSError).code))
        print("Read error 0x\(String(code, radix: 16))")
        // A failed transfer stalls the pipe; clear it or every later read fails too
        try? pipe.clearStall()
        Thread.sleep(forTimeInterval: 0.5)
        continue
    }

    let bytes = Array(UnsafeBufferPointer(
        start: buffer.bytes.assumingMemoryBound(to: UInt8.self),
        count: transferred
    ))

    if bytes != last {
        last = bytes
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("[\(transferred)B] \(hex)")
        if let decoded = decodeXbox360(bytes) {
            print("    \(decoded)")
        }
    }
}
