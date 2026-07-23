# GlassChat

Fully offline peer-to-peer messaging for iOS. 1:1 and group text over Multipeer Connectivity (Bluetooth + local Wi‑Fi). No servers, no internet, no accounts.

## Features

- **1:1 messages** — discover nearby peers and chat instantly
- **Group messages** — up to 8 members (Multipeer Connectivity limit)
- **Photos over mesh** — thumbnail-first offers; Multipeer resource fast path + BLE chunk pull
- **Reliable delivery** — ACK + outbox retry when peers reconnect
- **Lightweight** — SwiftUI + SwiftData + Multipeer/BLE only (no third-party deps)
- **Liquid glass UI** — iOS 26 `glassEffect` with Material fallback for older devices

## Requirements

- Xcode 16+
- iOS 17.0+ deployment target
- **Physical devices** for Multipeer Connectivity testing (Simulator is unreliable)

## Open the project

If you have [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd GlassChat
xcodegen generate
open GlassChat.xcodeproj
```

Or create a new iOS App project in Xcode named `GlassChat`, set the deployment target to iOS 17, then drag the `GlassChat/` source folder into the project and add the unit test targets from `GlassChatTests/`.

`Info.plist` already includes:

- `NSLocalNetworkUsageDescription`
- `NSBonjourServices`: `_glass-chat._tcp`, `_glass-chat._udp`

## Architecture

```
UI (SwiftUI) → ChatService → MultipeerTransport + SwiftData
```

See [`../PLAN.md`](../PLAN.md) for the full design.

## Tests

```bash
xcodebuild test -scheme GlassChat -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Privacy

All traffic stays on-device / on the local radio link. Message history is stored locally with SwiftData. Peer identity UUID is kept in the Keychain.
