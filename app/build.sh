#!/bin/zsh
# Build Stow.app, sign it ad hoc and install it in ~/Applications.
# STOW_NO_INSTALL=1 builds into ./build/Stow.app and stops (used by CI).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0}"
swift build -c release
APP=build/Stow.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stow "$APP/Contents/MacOS/Stow"
# Optional icon: put a 1024px PNG at assets/icon-1024.png
ICON_SRC="assets/icon-1024.png"
if [[ -f "$ICON_SRC" ]]; then
  SET=build/Stow.iconset; mkdir -p $SET
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out $SET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out $SET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $SET -o "$APP/Contents/Resources/Stow.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.steedymidds.stow</string>
  <key>CFBundleName</key><string>Stow</string>
  <key>CFBundleDisplayName</key><string>Stow</string>
  <key>CFBundleExecutable</key><string>Stow</string>
  <key>CFBundleIconFile</key><string>Stow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Stow contributors. MIT licence.</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
if [[ -n "${STOW_NO_INSTALL:-}" ]]; then echo "built $APP (not installed)"; exit 0; fi
DEST="$HOME/Applications/Stow.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST" && cp -R "$APP" "$DEST"
echo "installed $DEST"
# Don't leave a second copy of the app where Spotlight and Launchpad find it.
rm -rf build
