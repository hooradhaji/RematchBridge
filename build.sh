#!/bin/zsh
# Builds RematchBridge.app (menu-bar app) and the gipdump diagnostic tool into ./build.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.2
APP=build/RematchBridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal binary: Apple Silicon + Intel.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 \
    Sources/Core/*.swift Sources/App/*.swift -o "build/RematchBridge-$ARCH"
done
lipo -create build/RematchBridge-arm64 build/RematchBridge-x86_64 -output "$APP/Contents/MacOS/RematchBridge"
swiftc -O -swift-version 5 Sources/Core/*.swift Sources/Tools/gipdump/main.swift -o build/gipdump
cp -R Extension "$APP/Contents/Resources/Extension"
swiftc -O Sources/Tools/make-icon/main.swift -o build/make-icon
build/make-icon build/icon >/dev/null
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.rematchbridge</string>
  <key>CFBundleName</key><string>RematchBridge</string>
  <key>CFBundleDisplayName</key><string>RematchBridge</string>
  <key>CFBundleExecutable</key><string>RematchBridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 hooradhaji · MIT License · Not affiliated with Turtle Beach or Microsoft.</string>
</dict></plist>
PLIST
# Sign with the personal certificate if it exists (see scripts/make-signing-cert.sh), so
# macOS keeps the Accessibility permission across builds; otherwise ad-hoc.
IDENTITY="${SIGN_IDENTITY:-RematchBridge Code Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
  && codesign --force --sign "$IDENTITY" --identifier local.rematchbridge "$APP" 2>/dev/null; then
  echo "signed with \"$IDENTITY\""
else
  codesign --force --sign - --identifier local.rematchbridge "$APP"
  echo "ad-hoc signed (run scripts/make-signing-cert.sh to keep permissions across builds)"
fi
codesign --verify --strict "$APP"
echo "built $APP"
