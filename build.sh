#!/bin/bash
# Builds Inkwell.app. Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Inkwell.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -module-name Inkwell \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/Inkwell-$arch"
done
lipo -create build/Inkwell-arm64 build/Inkwell-x86_64 -output "$APP/Contents/MacOS/Inkwell"
rm build/Inkwell-arm64 build/Inkwell-x86_64

echo "→ Bundling resources"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/preview "$APP/Contents/Resources/preview"
if [ ! -f build/AppIcon.icns ]; then
  swift Tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

if [ "${1:-}" = "install" ]; then
  echo "→ Installing to /Applications"
  osascript -e 'tell application id "app.inkwell.markdown" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/Inkwell.app
  cp -R "$APP" /Applications/Inkwell.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Inkwell.app
fi
echo "✓ Done: $APP"
