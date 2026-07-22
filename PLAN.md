# GlassChat — Offline P2P Messaging for iOS

A single-purpose SwiftUI app: nearby 1:1 and group text messaging over Multipeer Connectivity, zero servers, zero third-party dependencies.

## Architecture

```
UI (SwiftUI) → ChatService → MultipeerTransport + SwiftData
```

- **Send:** ChatView → ChatService.send → Message(pending) → MultipeerTransport → ACK → delivered
- **Receive:** MultipeerTransport → ChatService.handle → idempotent insert → ACK
- Event subscription is created once in `ChatService.init` (AsyncStream is single-consumer)
- Transport never touches SwiftData; UI never touches transport

## Transport

- Service type: `glass-chat`
- Single MCSession mesh; logical 1:1 / group routing
- WireFrame kinds: `hello`, `message`, `ack`
- UUID peer identity in Keychain; display name via hello / re-hello
- Groups max 8 members (MC ceiling); invite skipped at 7 remote peers
- Nearby visibility preference persisted; scene-phase only restarts when enabled

## Data model (SwiftData)

- `Peer`, `Chat` (direct|group), `Message` with `DeliveryStatus` + `ackedBy`
- Outbox = fetch `isFromMe && status != delivered|failed`

## UI

- NavigationStack routes: chat list, peer browser, new group, settings
- Liquid glass via `#if compiler(>=6.2)` + `#available(iOS 26.0, *)`
- Material / solid fallbacks for older OS and Reduce Transparency

## Reliability

- Client UUID idempotency
- Event-driven outbox flush on peer connect + foreground
- Per-member ACKs for groups (weakest-member delivery status)

## Explicit non-goals

Media, read receipts, mesh relaying, groups > 8, custom E2E crypto beyond MC encryption, any server.
