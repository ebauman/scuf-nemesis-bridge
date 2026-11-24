# SCUF Bridge

Makes the SCUF Nemesis Pro 8K (USB 1B1C:3A3F) usable on macOS by reading its
Xbox 360-style XInput interface (USB interface 0, which macOS has no driver
for) and re-publishing it as a standard HID gamepad via CoreHID.

The virtual gamepad layout:

- Left stick: X/Y. Right stick: Rx/Ry.
- Triggers: Z (LT) and Rz (RT).
- D-pad: hat switch.
- Buttons 1-11: A B X Y LB RB Back Start LS RS Guide.

## Test without the entitlement

```
./build.sh
build/ScufBridge.app/Contents/MacOS/scuf-bridge --dry-run
```

Press buttons and move the sticks; each change prints the translated report.

## Enable the virtual gamepad

Creating the virtual device requires the restricted
`com.apple.developer.hid.virtual.device` entitlement.

1. Request it at <https://developer.apple.com/system-extensions/> (the
   entitlement request link there covers the CoreHID virtual device).
2. Once granted, in Certificates, Identifiers & Profiles:
   - Register a macOS App ID `com.eamonbauman.scuf-bridge` (or set
     `BUNDLE_ID` when building) and enable the HID virtual device capability.
   - Register this Mac as a device using its Provisioning UDID from
     `system_profiler SPHardwareDataType | grep "Provisioning UDID"`.
   - Create a macOS App Development profile for that App ID, your
     Apple Development certificate, and this Mac. Download it.
3. Build signed and run:

   ```
   ./build.sh ~/Downloads/ScufBridge.provisionprofile
   build/ScufBridge.app/Contents/MacOS/scuf-bridge
   ```

4. Leave it running, then start the game. The controller shows up as
   "SCUF Bridge Gamepad".

`TEAM_ID`, `BUNDLE_ID` and `IDENTITY` can be overridden as environment
variables to `build.sh`.

## Diagnostics

`tools/` holds the standalone scripts used to work out the controller's
interfaces:

- `scuf-diagnostic.swift` polls the two vendor HID interfaces (these carry
  Corsair configuration traffic, not gamepad input).
- `scuf-xinput.swift` reads and decodes raw reports from the XInput interface.

Run either with `swift tools/<name>.swift`.
