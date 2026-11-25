#!/bin/zsh
# Build release + wrap into LickMyPaw.app (ad-hoc signed)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=LickMyPaw.app
rm -rf $APP SpaceLens.app && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/LickMyPaw $APP/Contents/MacOS/
cp -R .build/release/LickMyPaw_LickMyPaw.bundle $APP/Contents/Resources/
cp assets/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LickMyPaw</string>
<key>CFBundleDisplayName</key><string>LickMyPaw</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>LickMyPaw</string>
<key>CFBundleIdentifier</key><string>org.lickmypaw.app</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>it</string><string>fr</string><string>es</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --sign - $APP
echo "built $PWD/$APP"
