#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CliMate"
BUNDLE_ID="ai.umate.climate.ios"

DEVICE="${1:-}"
TEAM_ID="${TEAM_ID:-}"

if [[ -z "$DEVICE" ]]; then
  echo "Usage: $0 <device-udid|device-name>" >&2
  echo "Example: $0 00008130-001421A80198001C" >&2
  echo "Tip: xcrun devicectl list devices" >&2
  exit 2
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "Missing TEAM_ID for code signing." >&2
  echo "Set TEAM_ID to your Apple Developer Team ID (10 characters), then rerun:" >&2
  echo "  TEAM_ID=YOURTEAMID $0 $DEVICE" >&2
  exit 2
fi

cd "$ROOT_DIR"

./scripts/bootstrap-tailscale-kit.sh
xcodegen generate

DERIVED_DATA="$ROOT_DIR/build"

XCB_FLAGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Debug
  -derivedDataPath "$DERIVED_DATA"
  -destination "id=$DEVICE"
  -allowProvisioningUpdates
)

if [[ -n "$TEAM_ID" ]]; then
  XCB_FLAGS+=(
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_STYLE=Automatic
    PROVISIONING_PROFILE_SPECIFIER=
  )
fi

echo "Building..."
xcodebuild "${XCB_FLAGS[@]}" build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found: $APP_PATH" >&2
  exit 1
fi

echo "Installing to device..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"

echo "Launching (console attached)..."
echo "(If you don't see logs, ensure the app uses print/NSLog and isn't killed immediately.)"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" --terminate-existing --console
