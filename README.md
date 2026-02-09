# CliMate

MVP: run `codex app-server` on macOS and connect from iPhone over Tailscale.

## Server (Go, embedded tailnet) — current

Prereqs:

- `codex` installed and able to run `codex app-server`
- Tailnet access control allows your iPhone device/user to reach this Mac on the chosen port
- Go installed + a Tailscale auth key (`TS_AUTHKEY=tskey-...`)

Run:

```bash
cd server
TS_AUTHKEY=tskey-auth-... go run ./cmd/climate-server --port 4500 --ts-hostname climate-mac
```

Optional build:

```bash
cd server
go build -o climate-server ./cmd/climate-server
./climate-server --port 4500 --ts-auth-key tskey-auth-... --ts-hostname climate-mac
```

This starts an HTTP bridge on `http://127.0.0.1:4500` that spawns `codex app-server`
(stdio transport) and exposes:

- `POST /rpc` for JSON-RPC messages
- `GET /events` for SSE stream of JSON-RPC messages

The server prints the iOS base URL (MagicDNS) when available.

## iOS (client)

See `ios/README.md`.

## Notes

- `codex app-server` WebSocket transport is documented as experimental/unsupported.
- iOS ATS often blocks `http://`; this MVP uses an ATS override in `ios/CliMateApp/Resources/Info.plist`.

## Legacy Rust server (deprecated)

The previous Rust implementation lives in `legacy/rust-server` for reference.
It is not maintained and will be removed once the Go server fully replaces it.
