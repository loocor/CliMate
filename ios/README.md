# CliMate iOS

This folder contains a minimal SwiftUI client that connects to `codex app-server` over WebSocket.

The iOS app is generated via XcodeGen (so we don't commit a large `.pbxproj`).

## Generate the Xcode project

From `ios/CliMateApp`:

```bash
xcodegen --version || brew install xcodegen
xcodegen generate
open CliMate.xcodeproj
```

## Use

- In the app, paste the server URL (example: `ws://my-mac.tailnet-name.ts.net:4500`)
- Tap Connect
- Type a message and tap Send

Approvals (command/file) are shown as a confirmation dialog.
