# NSO GC Driver

Native macOS driver for Nintendo Switch Online GameCube controllers. The app is an active native SwiftUI implementation.

This is an independent project and is not affiliated with or endorsed by
Nintendo. Nintendo, Nintendo Switch, and GameCube are trademarks of their
respective owner.

## Features

- `IOKit.hid` for USB HID discovery, reports, initialization, and rumble
- `CoreBluetooth` for BLE discovery, notifications, initialization, and rumble
- `Network` for a Cemuhook/DSU UDP server compatible with Dolphin and other DSU clients
- SwiftUI for the launcher and live controller monitor
- One virtual HID gamepad per occupied player slot, remapped on reorder/disconnect
- Switchable Dolphin/SInput and standard HID compatibility modes
- Per-controller stick noise and analog-trigger rest calibration without sample-delay filtering
- Player slot assignment, controller reordering, LEDs, and rumble
- Live battery level and charging status in the app, virtual gamepad, and DSU
- Dashboard, live GameCube controller tester, profile editor, integrations, and diagnostics
- Persistent named remapping profiles with axis inversion, C-stick sensitivity, and JSON import/export
- Live report-rate, malformed-report, virtual-device, DSU client, and traffic diagnostics
- Privacy-filtered support export, with raw logs kept in an Advanced section
- Menu bar status and quick actions, first-run permission checks, and optional launch at login

Remembered-device reconnection is not available on macOS. I couldn't get it to work,
help is appreciated.

## Build and use

Open `NSOGCDriver.xcodeproj` in Xcode and run the `NSOGCDriver` scheme. The driver starts automatically on app launch. macOS will ask for Bluetooth permission the first time BLE is used.

Choose the virtual controller mode on the **Integrations** page. **Dolphin / SInput** supports rumble in current Dolphin builds. **Compatibility mode** uses standard HID controls for apps with older SDL 2 controller stacks, but virtual-controller rumble is unavailable in that mode on macOS.

To use the DSU server with Dolphin:

1. Open **Controllers**, then **Alternate Input Sources**.
2. Enable **DSU Client**, click **Add**, and enter `127.0.0.1` as the server IP and the port shown in NSO GC Driver (normally `26760`).
3. Set the GameCube port to **Standard Controller**, click **Configure**, and select the `DSUClient/...` device.
4. Map the controls in Dolphin.

Other DSU-compatible clients can connect to the same address shown in the app.

The driver supports vendor/product matching (`057e:2073`), Nintendo's 12-bit nibble-packed stick format, player LEDs, 0x30 full input mode, BLE report decoding, slot-based DSU output, and Dolphin rumble.

## AI

This app was vibe coded. Sue me. I don't want to spend my non-working hours of the day
debugging MacOS's Bluetooth stack, I just want to play Mario Kart.

## License

MIT
