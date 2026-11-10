#!/usr/bin/env bash
# Builds MenuCraft.app into ./build. Pass --run to launch it afterwards, or
# --install to replace /Applications/MenuCraft.app and launch that.
# Signs with CODESIGN_IDENTITY, else the "MenuCraft Local Signing" keychain identity
# if present, else ad-hoc. A stable identity lets macOS keep granted permissions
# across rebuilds (ad-hoc signatures change on every build).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/MenuCraft.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MenuCraft" "$APP/Contents/MacOS/MenuCraft"
cp Resources/Info.plist "$APP/Contents/Info.plist"

LOCAL_IDENTITY="MenuCraft Local Signing"
if [[ -z "${CODESIGN_IDENTITY:-}" ]] && security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    CODESIGN_IDENTITY="$LOCAL_IDENTITY"
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

quit_running() {
    pkill -x MenuCraft 2>/dev/null || true
    for _ in {1..50}; do
        pgrep -x MenuCraft >/dev/null || return 0
        sleep 0.1
    done
}

case "${1:-}" in
--run)
    quit_running
    open "$APP"
    ;;
--install)
    quit_running
    rm -rf /Applications/MenuCraft.app
    cp -R "$APP" /Applications/
    # LaunchServices can briefly refuse a just-replaced bundle (error -600).
    for _ in 1 2 3 4 5; do
        open /Applications/MenuCraft.app 2>/dev/null && break
        sleep 1
    done
    echo "Installed /Applications/MenuCraft.app"
    ;;
esac
