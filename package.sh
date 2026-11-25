#!/bin/zsh
# Build the app and produce release artifacts in dist/: a DMG and a zipped .app (+ SHA-256 sums).
# Usage: VERSION=0.1.0 ./package.sh        (CI sets VERSION from the git tag)
set -e
cd "$(dirname "$0")"
VER=${VERSION:-0.1.0}
ARCH=$(uname -m)
VERSION=$VER ./bundle.sh
rm -rf dist && mkdir -p dist/dmg-stage
cp -R LickMyPaw.app dist/dmg-stage/
ln -s /Applications dist/dmg-stage/Applications
hdiutil create -volname "LickMyPaw $VER" -srcfolder dist/dmg-stage -ov -format UDZO "dist/LickMyPaw-$VER-macos-$ARCH.dmg" >/dev/null
rm -rf dist/dmg-stage
# ditto keeps the bundle structure, symlinks and the ad-hoc signature intact (plain `zip` may not)
ditto -c -k --keepParent LickMyPaw.app "dist/LickMyPaw-$VER-macos-$ARCH.zip"
(cd dist && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt)
ls -lh dist
