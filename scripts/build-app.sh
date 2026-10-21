#!/usr/bin/env bash
# Builds Tjuv.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Tjuv.app"

# Apple Silicon only.
ARCHS=(--arch arm64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tjuv" "$APP/Contents/MacOS/Tjuv"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The version comes from the release tag, not a commit: VERSION when releasing, otherwise the latest
# tag, so a local build says which release it's built on. The build number only ever goes up.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  # Quit politely so the app restores lid sleep itself; fall back to a signal if it doesn't.
  if pgrep -x Tjuv >/dev/null; then
    osascript -e 'quit app id "com.mj0lken.tjuv"' 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -x Tjuv >/dev/null || break; sleep 1; done
    pkill -x Tjuv 2>/dev/null || true
  fi
  rm -rf "/Applications/Tjuv.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Tjuv.app"
  open /Applications/Tjuv.app
fi
