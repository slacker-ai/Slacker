#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: scripts/create-dmg.sh /path/to/Slacker.app /path/to/Slacker.dmg" >&2
  exit 64
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
APP_NAME="$(basename "$APP_PATH")"
VOLUME_NAME="${APP_NAME%.app}"
BUILD_DIR="$(dirname "$OUTPUT_DMG")"
TEMP_DMG="$BUILD_DIR/$VOLUME_NAME.temp.dmg"
MOUNT_DIR="$(mktemp -d)"

if [[ ! -d "$APP_PATH" ]]; then
  echo "app bundle does not exist: $APP_PATH" >&2
  exit 66
fi

APP_SIZE_MB="$(du -sm "$APP_PATH" | awk '{print $1}')"
DMG_SIZE_MB=$((APP_SIZE_MB + 100))

mkdir -p "$BUILD_DIR"
rm -f "$OUTPUT_DMG" "$TEMP_DMG"

cleanup() {
  if mount | grep -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$MOUNT_DIR" "$TEMP_DMG"
}
trap cleanup EXIT

hdiutil create -size "${DMG_SIZE_MB}m" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  "$TEMP_DMG" \
  -quiet

hdiutil attach "$TEMP_DMG" \
  -mountpoint "$MOUNT_DIR" \
  -nobrowse \
  -quiet

ditto "$APP_PATH" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"

hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" \
  -quiet
