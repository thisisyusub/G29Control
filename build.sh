#!/bin/bash
# Build G29 Control.app
#
#   ./build.sh             build and open the app
#   ./build.sh --install   build and install into /Applications
#   ./build.sh --release   build and package dist/G29Control.zip + dist/G29Control.dmg
#
# Needs Apple's compiler: install once with  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP_NAME="G29 Control"
APP="build/$APP_NAME.app"
VERSION="${VERSION:-1.0.1}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Run:  xcode-select --install   then run this script again."
  exit 1
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling for Apple Silicon and Intel…"
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -framework IOKit -framework SwiftUI -framework AppKit \
    Sources/G29Control.swift -o "build/G29Control-$ARCH"
done
lipo -create build/G29Control-arm64 build/G29Control-x86_64 -output "$APP/Contents/MacOS/G29Control"
rm build/G29Control-arm64 build/G29Control-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.g29control</string>
  <key>CFBundleExecutable</key><string>G29Control</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Optional icon: put an AppIcon.icns in Resources/ and it is picked up automatically
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature (free). Lets macOS remember permissions between launches.
codesign --force --deep -s - "$APP"
echo "Built: $(pwd)/$APP"

case "$MODE" in
  --install)
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
    echo "Installed to /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    ;;
  --release)
    mkdir -p dist
    rm -f dist/G29Control.zip dist/G29Control.dmg
    ditto -c -k --keepParent "$APP" dist/G29Control.zip
    STAGE="build/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO dist/G29Control.dmg >/dev/null
    echo "Release files:"
    ls -lh dist
    ;;
  *)
    open "$APP"
    ;;
esac
