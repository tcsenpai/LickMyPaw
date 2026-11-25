#!/bin/zsh
# Smoke test of the PACKAGED app, the way a user's machine sees it: unzip somewhere else and hide .build,
# so nothing can be resolved from the build directory (this is what hid a crash on launch in v0.1.0).
# Usage: ./smoke.sh dist/LickMyPaw-<ver>-macos-<arch>.zip
set -e
cd "$(dirname "$0")"
ZIP=$1; [ -f "$ZIP" ] || { echo "usage: $0 <zip>"; exit 2; }
T=$(mktemp -d)
[ -d .build ] && mv .build "$T/.build-hidden"
trap '[ -d "$T/.build-hidden" ] && mv "$T/.build-hidden" .build; rm -rf "$T"' EXIT
ditto -x -k "$ZIP" "$T"
BIN="$T/LickMyPaw.app/Contents/MacOS/LickMyPaw"
OUT=$("$BIN" --i18n-check 2>&1) || { echo "FAIL: i18n-check crashed:\n$OUT"; exit 1 }
echo "$OUT" | grep -q "Ricomincia" || { echo "FAIL: translations not found in the packaged app:\n$OUT"; exit 1 }
echo "ok: packaged app loads its resources and translations"
# Offscreen render of the real window needs a window server; best effort only.
if LICKMYPAW_LANG=it LICKMYPAW_HOME="$T/home" "$BIN" --render-page settings "$T/s.png" >/dev/null 2>&1 && [ -s "$T/s.png" ]; then echo "ok: offscreen render of the UI"; else echo "note: offscreen render skipped (no window server?)"; fi
echo "smoke ok"
