# CliMate iOS

This folder contains a minimal SwiftUI client that connects to the CliMate server over HTTP JSON-RPC + SSE.

The iOS app is generated via XcodeGen (so we don't commit a large `.pbxproj`).

## Generate the Xcode project

From `ios/CliMateApp`:

```bash
xcodegen --version || brew install xcodegen
./scripts/bootstrap-tailscale-kit.sh
xcodegen generate
open CliMate.xcodeproj
```

## Deploy from CLI (no Xcode UI)

From `ios/CliMateApp`:

```bash
xcrun devicectl list devices
./scripts/run-device.sh <your-device-udid>
```

If code signing fails, set `TEAM_ID`:

```bash
TEAM_ID=YOURTEAMID ./scripts/run-device.sh <your-device-udid>
```

## Use

- Run `./scripts/bootstrap-tailscale-kit.sh` to build/copy `TailscaleKit.xcframework` into `Vendor/` (ignored by git)
- In the app, paste the server base URL (try `http://<mac>.<tailnet>.ts.net:4500` first; if needed, `http://100.x.y.z:4500`)
- Paste a Tailscale auth key (generate in the Tailscale admin console)
- Tap Connect
- Type a message and tap Send

Approvals (command/file) are shown as a confirmation dialog.
