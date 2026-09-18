# NSO GC Driver

Native macOS driver for Nintendo Switch Online GameCube controllers. The app is an active native SwiftUI implementation.

This is an independent project and is not affiliated with or endorsed by
Nintendo. Nintendo, Nintendo Switch, and GameCube are trademarks of their
respective owner.

## Features

- `IOKit.hid` for USB HID discovery, reports, initialization, and rumble
- `CoreBluetooth` for BLE discovery, notifications, initialization, and rumble
- `Network` for the Cemuhook/DSU UDP server used by Dolphin
- SwiftUI for the launcher and live controller monitor
- One virtual HID gamepad per occupied player slot, remapped on reorder/disconnect
- Per-controller stick noise and analog-trigger rest calibration without sample-delay filtering
- Player slot assignment, controller reordering, LEDs, and rumble
- Live battery level and charging status in the app, virtual gamepad, and DSU
- Collapsed diagnostic logs with one-click copy

Remembered-device reconnection is not available on macOS. I couldn't get it to work,
help is appreciated.

## Build and use

Open `NSOGCDriver.xcodeproj` in Xcode and run the `NSOGCDriver` scheme. The driver starts automatically on app launch. macOS will ask for Bluetooth permission the first time BLE is used. In Dolphin, configure a DSU client at `127.0.0.1:26760`.

The driver supports vendor/product matching (`057e:2073`), Nintendo's 12-bit nibble-packed stick format, player LEDs, 0x30 full input mode, BLE report decoding, slot-based DSU output, and Dolphin rumble.

## AI

This app was vibe coded. Sue me. I don't want to spend my non-working hours of the day
debugging MacOS's Bluetooth stack, I just want to play Mario Kart.

## License

MIT
