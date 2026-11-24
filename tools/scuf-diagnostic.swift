
import Foundation
import IOKit
import IOKit.hid

// Line-buffer stdout so output survives CTRL+C and piping to tee
setvbuf(stdout, nil, _IOLBF, 0)

let manager = IOHIDManagerCreate(
    kCFAllocatorDefault,
    IOOptionBits(kIOHIDOptionsTypeNone)
)

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: 0x1B1C,
    kIOHIDProductIDKey as String: 0x3A3F
]

IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard result == kIOReturnSuccess else {
    fatalError("Manager open failed: \(result)")
}

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    fatalError("No devices found")
}

for (index, device) in devices.enumerated() {
    print("\nINTERFACE \(index + 1)")

    let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("Open: \(open)")

    guard open == kIOReturnSuccess else { continue }

    guard let elements = IOHIDDeviceCopyMatchingElements(
        device,
        nil,
        IOOptionBits(kIOHIDOptionsTypeNone)
    ) as? [IOHIDElement] else {
        continue
    }

    for element in elements {
        let type = IOHIDElementGetType(element)

        print("""
          Cookie: \(IOHIDElementGetCookie(element))
          Type: \(type.rawValue)
          Page: 0x\(String(IOHIDElementGetUsagePage(element), radix: 16))
          Usage: 0x\(String(IOHIDElementGetUsage(element), radix: 16))
          Report ID: \(IOHIDElementGetReportID(element))
        """)
    }
}

// Last-seen raw bytes per (interface, cookie), so we only print changes
var lastSeen: [String: [UInt8]] = [:]

print("\nInspecting current element values...")
print("Press buttons and move sticks now.")

while true {
    for (index, device) in devices.enumerated() {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else {
            continue
        }

        for element in elements {
            // IOHIDDeviceGetValue wants a non-optional out-pointer; passing an
            // implicitly-unwrapped nil traps, so hand it raw storage to fill in.
            let valuePtr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { valuePtr.deallocate() }

            let status = IOHIDDeviceGetValue(
                device,
                element,
                valuePtr
            )

            if status == kIOReturnSuccess {
                // Get rule: the value is not retained for us
                let actual = valuePtr.pointee.takeUnretainedValue()
                let length = IOHIDValueGetLength(actual)
                let bytes = Array(UnsafeBufferPointer(
                    start: IOHIDValueGetBytePtr(actual),
                    count: length
                ))

                let key = "\(index + 1):\(IOHIDElementGetCookie(element))"
                if lastSeen[key] != bytes {
                    lastSeen[key] = bytes
                    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("Interface \(index + 1): Cookie \(IOHIDElementGetCookie(element)) [\(length)B] = \(hex)")
                }
            }
        }
    }

    // Spin the run loop (not Thread.sleep) so HID can deliver updates between polls
    CFRunLoopRunInMode(.defaultMode, 0.1, false)
}

