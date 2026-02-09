# CliMate

MVP: run `codex app-server` on macOS and connect from iPhone over Tailscale.

## Server (Go, embedded tailnet) — current

Prereqs:

- `codex` installed and able to run `codex app-server`
- Tailnet access control allows your iPhone device/user to reach this Mac on the chosen port
- Go installed + a Tailscale auth key (`tskey-...`)

Run (config file):

```bash
cd server
cp config/config.example.yaml config/config.yaml
# edit ts_auth_key / ts_hostname / port as needed
go run ./cmd/climate-server
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

### Config (optional)

Supported sources (in order of precedence):

1. CLI flags
2. YAML config file

Default config path:

- `server/config/config.yaml` (repo root)
- `config/config.yaml` (when running inside `server/`)

You can override with:

```bash
go run ./cmd/climate-server --config /path/to/config.yaml
```

Example config:

```bash
cp server/config/config.example.yaml server/config/config.yaml
```

## iOS (client)

See `ios/README.md`.

## Notes

- `codex app-server` WebSocket transport is documented as experimental/unsupported.
- iOS ATS often blocks `http://`; this MVP uses an ATS override in `ios/CliMateApp/Resources/Info.plist`.
