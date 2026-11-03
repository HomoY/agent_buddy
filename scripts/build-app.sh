#!/bin/bash
# Builds Agent Buddy.app into ./build.
#   scripts/build-app.sh              build only, for this Mac's kind of processor
#   scripts/build-app.sh --install    build, copy to ~/Applications and (re)start it
#   scripts/build-app.sh --universal  for Apple silicon and Intel Macs both (as the disk image is)
set -euo pipefail

INSTALL=0
ARCHS=()
for argument in "$@"; do
  case "$argument" in
    --install) INSTALL=1 ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "unknown option: $argument" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# (An empty array can't be expanded under set -u in macOS's bash 3.2: hence the +.)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product AgentBuddy
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

if [ ! -f Support/AppIcon.icns ]; then
  swift scripts/make-icon.swift Support/AppIcon.icns || echo "warning: couldn't draw the icon; building without it"
fi

APP="$ROOT/build/Agent Buddy.app"
rm -rf "$APP" "$ROOT/build/HeadShow.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBuddy" "$APP/Contents/MacOS/AgentBuddy"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# The page that draws agents' answers (KaTeX, marked, highlight.js), as SwiftPM bundled it.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] && ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
# Signed with your Apple Development certificate when there is one (Xcode makes
# it with a free Apple ID): macOS then knows each new build as the same app, and
# keeps what you allowed it (Accessibility, Automation). Else ad hoc, which macOS
# takes for a new app after each build. Set AGENTBUDDY_SIGN_IDENTITY to choose.
IDENTITY="${AGENTBUDDY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ] && codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with your Apple Development certificate"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  # Agent Buddy was called HeadShow: quit and remove that copy, so reminders
  # don't come twice. Its settings stay, and Agent Buddy copies them on first launch.
  for id in io.github.homoy.agentbuddy io.github.homoy.headshow; do
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  done
  sleep 1
  pkill -x AgentBuddy >/dev/null 2>&1 || true
  pkill -x HeadShow >/dev/null 2>&1 || true
  rm -rf "$DEST/Agent Buddy.app" "$DEST/HeadShow.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/Agent Buddy.app"
  echo "Installed and started $DEST/Agent Buddy.app"
fi
