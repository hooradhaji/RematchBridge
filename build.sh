#!/bin/zsh
# Builds RematchBridge.app (menu-bar app) and the gipdump diagnostic tool into ./build.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.0
APP=build/RematchBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/Core/*.swift Sources/App/*.swift -o "$APP/Contents/MacOS/RematchBridge"
swiftc -O -swift-version 5 Sources/Core/*.swift Sources/Tools/gipdump/main.swift -o build/gipdump
cp -R Extension "$APP/Contents/Resources/Extension"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.rematchbridge</string>
  <key>CFBundleName</key><string>RematchBridge</string>
  <key>CFBundleDisplayName</key><string>RematchBridge</string>
  <key>CFBundleExecutable</key><string>RematchBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Personal build. GIP details informed by Linux xpad and OpenJoystickDriver (MIT).</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.rematchbridge "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
