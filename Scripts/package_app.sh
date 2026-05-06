#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-WindowLockRecorder}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
SOURCE_RESOURCES_DIR="${SOURCE_RESOURCES_DIR:-$ROOT_DIR/Resources}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_APP="${INSTALL_APP:-0}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
RESET_TCC="${RESET_TCC:-0}"
RELAUNCH_APP="${RELAUNCH_APP:-0}"
CREATE_ZIP="${CREATE_ZIP:-0}"
CREATE_DMG="${CREATE_DMG:-0}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/$APP_NAME.dmg}"
ZIP_PATH="${ZIP_PATH:-$DIST_DIR/$APP_NAME.zip}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/scripts/release-entitlements.plist}"
NOTARIZE_APP="${NOTARIZE_APP:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DMG_STAGING_DIR="$DIST_DIR/.dmg-staging"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-$APP_NAME}"
VERSION="${VERSION:-1.0.0}"
SHORT_VERSION="${SHORT_VERSION:-1.0.0}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.WindowLockRecorder}"

find_running_app_pids() {
  pgrep -f "$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
}

stop_running_app_if_needed() {
  local pids
  pids="$(find_running_app_pids)"

  if [[ -z "$pids" ]]; then
    return 1
  fi

  echo "Stopping running $APP_NAME instance"

  if command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true
  fi

  pkill -TERM -f "$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME" || true

  for _ in {1..20}; do
    sleep 0.25
    if [[ -z "$(find_running_app_pids)" ]]; then
      return 0
    fi
  done

  echo "Forcing running $APP_NAME instance to exit"
  pkill -KILL -f "$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME" || true
  sleep 0.25
  return 0
}

was_running=0

remove_stale_relaunch_jobs() {
  launchctl list | awk '/dev\.local\.WindowLockRecorder\.(relaunch|launchctl-test)/ { print $3 }' | while read -r label; do
    [[ -n "$label" ]] && launchctl remove "$label" >/dev/null 2>&1 || true
  done
}

sign_path() {
  local target="$1"

  if ! command -v codesign >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "Signing $target with Developer ID identity"
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGNING_IDENTITY" "$target"
  else
    echo "Signing $target with ad-hoc identity"
    codesign --force --deep --sign - "$target"
  fi
}

verify_signature() {
  local target="$1"

  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$target"
  fi
}

notarize_file() {
  local target="$1"

  if [[ "$NOTARIZE_APP" != "1" ]]; then
    return 0
  fi

  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "NOTARIZE_APP=1 requires NOTARY_PROFILE to be set" >&2
    exit 1
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required for notarization" >&2
    exit 1
  fi

  echo "Submitting $target for notarization"
  xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait

  if [[ "$target" == *.app ]]; then
    echo "Stapling notarization ticket to app bundle"
    xcrun stapler staple "$target"
  elif [[ "$target" == *.dmg ]]; then
    echo "Stapling notarization ticket to disk image"
    xcrun stapler staple "$target"
  fi
}

mkdir -p "$DIST_DIR"

echo "Building $APP_NAME ($BUILD_CONFIGURATION)..."
swift build -c "$BUILD_CONFIGURATION" --package-path "$ROOT_DIR"

BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --package-path "$ROOT_DIR" --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -d "$SOURCE_RESOURCES_DIR" ]]; then
  echo "Copying bundle resources"
  ditto "$SOURCE_RESOURCES_DIR" "$RESOURCES_DIR"
fi

cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>WindowLockRecorder records the selected window you choose.</string>
</dict>
</plist>
EOF

sign_path "$APP_BUNDLE"
verify_signature "$APP_BUNDLE"

if [[ "$CREATE_ZIP" == "1" ]]; then
  echo "Creating zip archive at $ZIP_PATH"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
fi

if [[ "$CREATE_DMG" == "1" ]]; then
  echo "Creating disk image at $DMG_PATH"
  rm -rf "$DMG_STAGING_DIR"
  rm -f "$DMG_PATH"
  mkdir -p "$DMG_STAGING_DIR"
  ditto "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGING_DIR/Applications"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
fi

if [[ "$CREATE_DMG" == "1" && -n "$SIGNING_IDENTITY" ]]; then
  sign_path "$DMG_PATH"
  verify_signature "$DMG_PATH"
fi

if [[ "$NOTARIZE_APP" == "1" ]]; then
  if [[ "$CREATE_DMG" == "1" ]]; then
    notarize_file "$DMG_PATH"
  elif [[ "$CREATE_ZIP" == "1" ]]; then
    notarize_file "$ZIP_PATH"
  else
    notarize_file "$APP_BUNDLE"
  fi
fi

if [[ "$INSTALL_APP" == "1" ]]; then
  remove_stale_relaunch_jobs

  if stop_running_app_if_needed; then
    was_running=1
  fi

  echo "Installing app bundle to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP_BUNDLE"
  ditto "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
  touch "$INSTALLED_APP_BUNDLE"

  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u -f "$APP_BUNDLE" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1 || true
    "$LSREGISTER" -gc >/dev/null 2>&1 || true
  fi

  if [[ "$RESET_TCC" == "1" ]] && command -v tccutil >/dev/null 2>&1; then
    echo "Resetting Screen Recording permission for $BUNDLE_IDENTIFIER"
    tccutil reset ScreenCapture "$BUNDLE_IDENTIFIER" || true
  fi

  if [[ "$RELAUNCH_APP" == "1" && "$was_running" == "1" ]]; then
    echo "Relaunching installed app"
    open "$INSTALLED_APP_BUNDLE"
  fi

  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u -f "$APP_BUNDLE" >/dev/null 2>&1 || true
    "$LSREGISTER" -gc >/dev/null 2>&1 || true
  fi
fi

echo
echo "Packaged app:"
echo "  $APP_BUNDLE"

if [[ "$INSTALL_APP" == "1" ]]; then
  echo "Installed app:"
  echo "  $INSTALLED_APP_BUNDLE"
fi

if [[ "$CREATE_ZIP" == "1" ]]; then
  echo "  $ZIP_PATH"
fi

if [[ "$CREATE_DMG" == "1" ]]; then
  echo "  $DMG_PATH"
fi
