#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor"

LIBTAILSCALE_DIR_DEFAULT="/Volumes/External/GitHub/LibTailscale"
LIBTAILSCALE_DIR="${LIBTAILSCALE_DIR:-$LIBTAILSCALE_DIR_DEFAULT}"

if [[ ! -d "$LIBTAILSCALE_DIR" ]]; then
  echo "LibTailscale not found at '$LIBTAILSCALE_DIR'." >&2
  echo "Set LIBTAILSCALE_DIR to the repo path." >&2
  exit 1
fi

echo "Building TailscaleKit.xcframework from: $LIBTAILSCALE_DIR"
(
  cd "$LIBTAILSCALE_DIR/swift"
  # `make ios-fat` uses `xcodebuild -create-xcframework` which fails if the output already exists.
  rm -rf "./build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
  make ios-fat
)

SRC_XCFRAMEWORK="$LIBTAILSCALE_DIR/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
if [[ ! -d "$SRC_XCFRAMEWORK" ]]; then
  echo "Expected xcframework not found: $SRC_XCFRAMEWORK" >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"
rm -rf "$VENDOR_DIR/TailscaleKit.xcframework"
cp -R "$SRC_XCFRAMEWORK" "$VENDOR_DIR/"

echo "Copied: $VENDOR_DIR/TailscaleKit.xcframework"

echo "Done. Re-run: xcodegen generate"
