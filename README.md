# CliMate

MVP: run `codex app-server` on macOS and connect from iPhone over Tailscale.

## macOS (server)

Prereqs:

- `codex` installed and able to run `codex app-server`
- Tailscale installed and logged in on both Mac + iPhone
- Tailnet access control allows your iPhone device/user to reach this Mac on the chosen port

Run:

```bash
cargo run -- up --port 4500
```

This starts:

- a WebSocket bridge on `ws://127.0.0.1:4500` that spawns `codex app-server` (stdio transport) per client connection
- `tailscale serve --tcp 4500 tcp://127.0.0.1:4500 --bg` (tailnet-only)

Stop with Ctrl+C (CliMate will attempt to turn Serve off for that port).

If you need to find the connect address manually:

```bash
tailscale status
tailscale serve status
```

## iOS (client)

See `ios/README.md`.

## Notes

- `codex app-server` WebSocket transport is documented as experimental/unsupported.
- iOS ATS often blocks `ws://`; this MVP uses an ATS override in `ios/CliMateApp/Resources/Info.plist`.
- `tailscale serve --bg` persists until disabled (see `tailscale serve ... off`).
- Keep `codex app-server` bound to loopback and publish only via Tailscale Serve (prevents LAN exposure).
