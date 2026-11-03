#!/bin/bash
# Packs Agent Buddy.app into a disk image to install from: open it, then drag
# Agent Buddy onto Applications.
#   scripts/make-dmg.sh   builds the app, then build/AgentBuddy-<version>.dmg
#
# The app is signed as scripts/build-app.sh signs it (your Apple Development
# certificate, else ad hoc): it opens as is on this Mac. On another Mac, the
# first open is blocked: System Settings › Privacy & Security › Open Anyway
# (right-click › Open on macOS 13–14). Only a Developer ID signature, notarized
# by Apple, avoids that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# For Apple silicon and Intel Macs both.
"$ROOT/scripts/build-app.sh" --universal
APP="$ROOT/build/Agent Buddy.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/AgentBuddy-$VERSION.dmg"

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
cleanup() {
  if [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# What the window shows: the app, and Applications to drag it onto.
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Agent Buddy.app"
ln -s /Applications "$STAGE/Applications"

# Made writable first, to give the disk Agent Buddy's icon (without Finder),
# then compressed and read-only.
hdiutil create -quiet -volname "Agent Buddy" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/rw.dmg" -quiet -nobrowse -noverify -noautoopen -mountpoint "$MOUNT"
if [ -f "$APP/Contents/Resources/AppIcon.icns" ] && SETFILE="$(xcrun -f SetFile 2>/dev/null)"; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  "$SETFILE" -a C "$MOUNT"
fi
hdiutil detach "$MOUNT" -quiet
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
hdiutil verify -quiet "$DMG"
echo "Made $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
