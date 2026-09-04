#!/usr/bin/env bash

set -euo pipefail

# Legacy filename, current purpose: build a TrollStore-ready IPA with HID
# entitlements for realtime touch injection.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData-ios15-solumate-trollstore"
PACKAGE_DIR="$BUILD_DIR/ios15-solumate-trollstore-package"
PAYLOAD_DIR="$PACKAGE_DIR/Payload"
DEFAULT_ICON_DIR="$ROOT_DIR/ios_stream_v1/SolumateIos_Build/AppIcon.appiconset"
BACKUP_ICON_DIR="/Users/apple/Desktop/code/docs/backup_ubuntu/products/ios_stream_v1/SolumateIos_Build/AppIcon.appiconset"
ICON_DIR="${ICON_DIR:-$DEFAULT_ICON_DIR}"

APP_NAME="${APP_NAME:-RT-MMO 3}"
WDA_BUNDLE_ID="${WDA_BUNDLE_ID:-com.idbbagent.troll}"
APP_VERSION="${APP_VERSION:-11.4.1-universal-clean-external-sign}"
CONFIGURATION="${CONFIGURATION:-Release}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SIGNING_ENTITLEMENTS="${SIGNING_ENTITLEMENTS:-$ROOT_DIR/TrollStore-HID.entitlements}"
IPA_TIME="$(date +%d-%m-%Y)"
IPA_NAME="solumate-$IPA_TIME.ipa"
IPA_WORK_PATH="$BUILD_DIR/$IPA_NAME"
IPA_PATH="${OUTPUT_IPA_PATH:-$ROOT_DIR/$IPA_NAME}"
LOG_PATH="$BUILD_DIR/ios15-solumate-trollstore-build.log"
LAST_IPA_MARKER="$BUILD_DIR/.last-ios15-solumate-trollstore-ipa"

log() {
  printf '[build-ios15-solumate] %s\n' "$1"
}

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
  fi
}

remove_owned_path() {
  local target="$1"

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  case "$target" in
    "$DERIVED_DATA"|"$PACKAGE_DIR"|"$IPA_WORK_PATH"|"$LOG_PATH"|"$LAST_IPA_MARKER")
      chmod -R u+w "$target" >/dev/null 2>&1 || true
      rm -R -f "$target"
      ;;
    *)
      printf 'Refusing to clean unexpected path: %s\n' "$target" >&2
      exit 1
      ;;
  esac
}

plist_print() {
  local plist="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

require_trollstore_hid_entitlements() {
  local plist="$1"
  local label="$2"

  if [[ ! -f "$plist" ]]; then
    printf '%s not found: %s\n' "$label" "$plist" >&2
    exit 1
  fi

  local hid_manager
  local hid_dispatch
  local iokit_clients
  hid_manager="$(plist_print "$plist" 'com.apple.hid.manager.user-access-device')"
  hid_dispatch="$(plist_print "$plist" 'com.apple.private.hid.client.event-dispatch')"
  iokit_clients="$(plist_print "$plist" 'com.apple.security.exception.iokit-user-client-class')"

  if [[ "$hid_manager" != "true" || "$hid_dispatch" != "true" || "$iokit_clients" != *"IOHIDUserDeviceUserClient"* ]]; then
    printf '%s is missing required TrollStore HID entitlements.\n' "$label" >&2
    printf '  com.apple.hid.manager.user-access-device: %s\n' "${hid_manager:-missing}" >&2
    printf '  com.apple.private.hid.client.event-dispatch: %s\n' "${hid_dispatch:-missing}" >&2
    printf '  com.apple.security.exception.iokit-user-client-class: %s\n' "${iokit_clients:-missing}" >&2
    exit 1
  fi
}

codesign_nested_bundles() {
  local bundle="$1"
  local identity="$2"

  while IFS= read -r nested_bundle; do
    codesign --force --sign "$identity" "$nested_bundle"
  done < <(
    find "$bundle" -mindepth 1 -type d \( -name "*.framework" -o -name "*.xctest" -o -name "*.appex" \) -print |
      awk '{ print gsub("/", "/"), $0 }' |
      sort -rn |
      cut -d' ' -f2-
  )
}

sign_bundle_tree() {
  local bundle="$1"
  local entitlements="$2"
  local identity="$3"

  if [[ ! -d "$bundle" ]]; then
    printf 'Cannot sign missing bundle: %s\n' "$bundle" >&2
    exit 1
  fi
  require_trollstore_hid_entitlements "$entitlements" "Signing entitlements"

  while IFS= read -r built_file; do
    if file "$built_file" | grep -q 'Mach-O'; then
      codesign --force --sign "$identity" "$built_file"
    fi
  done < <(find "$bundle" -type f)

  codesign_nested_bundles "$bundle" "$identity"
  codesign --force --sign "$identity" --entitlements "$entitlements" "$bundle"
}

verify_signed_app_entitlements() {
  local bundle="$1"
  local entitlements_out

  entitlements_out="$(mktemp "$BUILD_DIR/signed-entitlements.XXXXXX.plist")"
  if ! codesign -d --entitlements :- "$bundle" >"$entitlements_out" 2>/dev/null; then
    rm -f "$entitlements_out"
    printf 'Unable to read entitlements from signed bundle: %s\n' "$bundle" >&2
    exit 1
  fi
  require_trollstore_hid_entitlements "$entitlements_out" "Signed app bundle"
  rm -f "$entitlements_out"
}

verify_macho_signatures() {
  local bundle="$1"
  local failed=0

  while IFS= read -r built_file; do
    if ! file "$built_file" | grep -q 'Mach-O'; then
      continue
    fi
    if ! codesign -v "$built_file" >/dev/null 2>&1; then
      printf 'Unsigned or invalid Mach-O after signing: %s\n' "$built_file" >&2
      failed=1
    fi
  done < <(find "$bundle" -type f)

  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
}

icon_dir_has_icons() {
  local candidate="$1"

  [[ -d "$candidate" ]] || return 1

  shopt -s nullglob
  local icon_files=("$candidate"/Icon-*.png)
  shopt -u nullglob

  [[ "${#icon_files[@]}" -gt 0 ]]
}

resolve_icon_dir() {
  local checked_paths=()
  local candidate

  for candidate in "$ICON_DIR" "$DEFAULT_ICON_DIR" "$BACKUP_ICON_DIR"; do
    checked_paths+=("$candidate")
    if icon_dir_has_icons "$candidate"; then
      ICON_DIR="$candidate"
      return 0
    fi
  done

  printf 'Icon directory not found. Checked:\n' >&2
  printf '  %s\n' "${checked_paths[@]}" >&2
  exit 1
}

if [[ ! -d "$XCODE_DEVELOPER_DIR" ]]; then
  printf 'Xcode developer dir not found: %s\n' "$XCODE_DEVELOPER_DIR" >&2
  exit 1
fi

resolve_icon_dir
require_trollstore_hid_entitlements "$SIGNING_ENTITLEMENTS" "Signing entitlements"

if [[ "$BUILD_DIR" != "$ROOT_DIR/build" ]]; then
  printf 'Refusing to clean unexpected build dir: %s\n' "$BUILD_DIR" >&2
  exit 1
fi

log "Cleaning previous iOS 15 build artifacts under: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
remove_owned_path "$DERIVED_DATA"
remove_owned_path "$PACKAGE_DIR"
remove_owned_path "$IPA_WORK_PATH"
remove_owned_path "$LOG_PATH"
remove_owned_path "$LAST_IPA_MARKER"

mkdir -p "$BUILD_DIR" "$PAYLOAD_DIR"

log "Using DEVELOPER_DIR=$XCODE_DEVELOPER_DIR"
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
log "Using icons from: $ICON_DIR"
log "Using TrollStore HID entitlements: $SIGNING_ENTITLEMENTS"

log "Building WDA payload with Xcode 15, configuration $CONFIGURATION, deployment target $IOS_DEPLOYMENT_TARGET"
(
  cd "$ROOT_DIR"
  xcodebuild \
    -project "$ROOT_DIR/WebDriverAgent.xcodeproj" \
    -scheme WebDriverAgentRunner \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination generic/platform=iOS \
    -derivedDataPath "$DERIVED_DATA" \
    build-for-testing \
    PRODUCT_BUNDLE_IDENTIFIER="$WDA_BUNDLE_ID" \
    WDA_PRODUCT_BUNDLE_IDENTIFIER="$WDA_BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_TESTABILITY=NO \
    DEBUG_INFORMATION_FORMAT=dwarf \
    GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
    COPY_PHASE_STRIP=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    DEPLOYMENT_POSTPROCESSING=YES \
    MTL_ENABLE_DEBUG_INFO=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    RUN_CLANG_STATIC_ANALYZER=NO
) 2>&1 | tee "$LOG_PATH"

APP_SOURCE="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/WebDriverAgentRunner-Runner.app"
APP_DEST="$PAYLOAD_DIR/WebDriverAgentRunner-Runner.app"
INFO_PLIST="$APP_DEST/Info.plist"

if [[ ! -d "$APP_SOURCE" ]]; then
  printf 'Built app not found: %s\n' "$APP_SOURCE" >&2
  exit 1
fi

log "Copying app into IPA payload"
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"

log "Applying Solumate app name and icons"
plist_set_string "$INFO_PLIST" "CFBundleIdentifier" "$WDA_BUNDLE_ID"
plist_set_string "$INFO_PLIST" "CFBundleName" "$APP_NAME"
plist_set_string "$INFO_PLIST" "CFBundleDisplayName" "$APP_NAME"
plist_set_string "$INFO_PLIST" "CFBundleShortVersionString" "$APP_VERSION"
plist_set_string "$INFO_PLIST" "MinimumOSVersion" "$IOS_DEPLOYMENT_TARGET"

if /usr/libexec/PlistBuddy -c "Print :CFBundleIcons" "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIcons" "$INFO_PLIST"
fi
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string Icon-60@2x" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:1 string Icon-60@3x" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:2 string Icon-40@2x" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:3 string Icon-40@3x" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:UIPrerenderedIcon bool false" "$INFO_PLIST"

for icon_file in "$ICON_DIR"/Icon-*.png; do
  cp "$icon_file" "$APP_DEST/"
done

log "Stripping Mach-O symbols before external signing"
while IFS= read -r built_file; do
  if file "$built_file" | grep -q 'Mach-O'; then
    strip -x "$built_file" >/dev/null 2>&1 || true
  fi
done < <(find "$APP_DEST" -type f)

log "Removing bundled XCTest runtime frameworks"
for runtime_entry in \
  "$APP_DEST/Frameworks/Testing.framework" \
  "$APP_DEST/Frameworks/XCTAutomationSupport.framework" \
  "$APP_DEST/Frameworks/XCTest.framework" \
  "$APP_DEST/Frameworks/XCTestCore.framework" \
  "$APP_DEST/Frameworks/XCTestSupport.framework" \
  "$APP_DEST/Frameworks/XCUIAutomation.framework" \
  "$APP_DEST/Frameworks/XCUnit.framework"
do
  if [[ -e "$runtime_entry" ]]; then
    chmod -R u+w "$runtime_entry" >/dev/null 2>&1 || true
    rm -R -f "$runtime_entry"
  fi
done

log "Removing signing residue"
while IFS= read -r residue_entry; do
  chmod -R u+w "$residue_entry" >/dev/null 2>&1 || true
  rm -R -f "$residue_entry"
done < <(find "$APP_DEST" -name "*.dSYM" -type d -prune)
while IFS= read -r residue_entry; do
  chmod -R u+w "$residue_entry" >/dev/null 2>&1 || true
  rm -R -f "$residue_entry"
done < <(find "$APP_DEST" -name "_CodeSignature" -type d -prune)
find "$APP_DEST" -name "embedded.mobileprovision" -type f -delete
while IFS= read -r built_file; do
  if file "$built_file" | grep -q 'Mach-O'; then
    codesign --remove-signature "$built_file" >/dev/null 2>&1 || true
  fi
done < <(find "$APP_DEST" -type f)

log "Signing app bundle for TrollStore HID realtime touch"
sign_bundle_tree "$APP_DEST" "$SIGNING_ENTITLEMENTS" "$SIGNING_IDENTITY"
log "Verifying signed app bundle"
codesign --verify --deep --strict --verbose=2 "$APP_DEST"
log "Verifying required HID entitlements"
verify_signed_app_entitlements "$APP_DEST"
log "Verifying Mach-O signatures"
verify_macho_signatures "$APP_DEST"

log "Creating TrollStore IPA: $IPA_WORK_PATH"
(
  cd "$PACKAGE_DIR"
  zip -qry "$IPA_WORK_PATH" Payload
)

log "Writing final IPA to: $IPA_PATH"
if [[ -e "$IPA_PATH" ]]; then
  chmod u+w "$IPA_PATH" >/dev/null 2>&1 || true
fi
cp -f "$IPA_WORK_PATH" "$IPA_PATH"

printf '%s\n' "$IPA_PATH" > "$LAST_IPA_MARKER"

log "Done"
log "IPA: $IPA_PATH"
log "Log: $LOG_PATH"
