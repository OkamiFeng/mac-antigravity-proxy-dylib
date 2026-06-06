#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="/Applications/Antigravity.app"
DEST_APP="$ROOT/Antigravity-Proxy.app"
PROXY_URL="socks5://127.0.0.1:7890"
ENV_PROXY_URL="http://127.0.0.1:7890"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  ./prepare-app-copy.sh [options]

Options:
  --source PATH       Source Antigravity.app. Default: /Applications/Antigravity.app
  --dest PATH         Destination app copy. Default: ./Antigravity-Proxy.app
  --proxy URL         Dylib SOCKS5 proxy URL. Default: socks5://127.0.0.1:7890
  --env-proxy URL     HTTP_PROXY/HTTPS_PROXY/ALL_PROXY URL. Default: http://127.0.0.1:7890
  --replace           Remove existing destination before copying.
  -h, --help          Show this help.
EOF
}

REPLACE=0
while (($#)); do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { echo "Missing --source value" >&2; exit 2; }
      SOURCE_APP="$2"
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || { echo "Missing --dest value" >&2; exit 2; }
      DEST_APP="$2"
      shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || { echo "Missing --proxy value" >&2; exit 2; }
      PROXY_URL="$2"
      shift 2
      ;;
    --env-proxy)
      [[ $# -ge 2 ]] || { echo "Missing --env-proxy value" >&2; exit 2; }
      ENV_PROXY_URL="$2"
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$SOURCE_APP" ]] || { echo "Source app not found: $SOURCE_APP" >&2; exit 1; }

if [[ ! -f "$ROOT/build/libantigravity_proxy.dylib" || ! -x "$ROOT/build/AntigravityProxyLauncher" ]]; then
  "$ROOT/build.sh"
fi

if [[ -e "$DEST_APP" ]]; then
  if [[ "$REPLACE" -eq 1 ]]; then
    rm -rf "$DEST_APP"
  else
    echo "Destination already exists: $DEST_APP" >&2
    echo "Use --replace to recreate it." >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$DEST_APP")" "$ROOT/build"

echo "Creating wrapper app..."
mkdir -p "$DEST_APP/Contents/MacOS" "$DEST_APP/Contents/Resources"

INNER_APP="$DEST_APP/Contents/Resources/Antigravity.app"
LAUNCHER_EXECUTABLE="$DEST_APP/Contents/MacOS/AntigravityProxyLauncher"

echo "Copying nested Antigravity.app..."
ditto "$SOURCE_APP" "$INNER_APP"
cp "$ROOT/build/AntigravityProxyLauncher" "$LAUNCHER_EXECUTABLE"
chmod +x "$LAUNCHER_EXECUTABLE"
cp "$ROOT/build/libantigravity_proxy.dylib" "$DEST_APP/Contents/Resources/libantigravity_proxy.dylib"

cat >"$DEST_APP/Contents/Resources/proxy.env" <<EOF
AG_PROXY=$PROXY_URL
AG_PROXY_LOG=1
AG_PROXY_TIMEOUT_MS=15000
HTTP_PROXY=$ENV_PROXY_URL
HTTPS_PROXY=$ENV_PROXY_URL
ALL_PROXY=$ENV_PROXY_URL
http_proxy=$ENV_PROXY_URL
https_proxy=$ENV_PROXY_URL
all_proxy=$ENV_PROXY_URL
NO_PROXY=localhost,127.0.0.1,::1,*.local
no_proxy=localhost,127.0.0.1,::1,*.local
EOF

PROXY_ICON_NAME="antigravity-proxy.icns"
PROXY_ICON_PATH="$DEST_APP/Contents/Resources/$PROXY_ICON_NAME"
CUSTOM_ICON_PNG="$ROOT/icon.png"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
ICON_SOURCE=""
if [[ -n "$ICON_FILE" ]]; then
  ICON_SOURCE="$SOURCE_APP/Contents/Resources/$ICON_FILE"
  [[ "$ICON_SOURCE" == *.icns ]] || ICON_SOURCE="$ICON_SOURCE.icns"
fi

generate_icns_from_png() {
  local source_png="$1"
  local output_icns="$2"
  local tmp_dir iconset
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/antigravity-proxy-icon.XXXXXX")"
  iconset="$tmp_dir/icon.iconset"
  mkdir -p "$iconset"

  sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset" -o "$output_icns"
  cp "$iconset/icon_512x512@2x.png" "${output_icns%.icns}.preview.png"
  rm -rf "$tmp_dir"
}

if [[ -f "$CUSTOM_ICON_PNG" ]]; then
  generate_icns_from_png "$CUSTOM_ICON_PNG" "$PROXY_ICON_PATH"
elif [[ -n "$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$PROXY_ICON_PATH"
else
  echo "Warning: cannot generate proxy icon; falling back to source icon." >&2
  if [[ -n "$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$PROXY_ICON_PATH"
  fi
fi

cp "$PROXY_ICON_PATH" "$INNER_APP/Contents/Resources/$PROXY_ICON_NAME"
ASAR_ICON_SOURCE="${PROXY_ICON_PATH%.icns}.preview.png"
if [[ -f "$CUSTOM_ICON_PNG" ]]; then
  ASAR_ICON_SOURCE="$CUSTOM_ICON_PNG"
fi
if [[ -x "$PYTHON_BIN" && -f "$ASAR_ICON_SOURCE" && -f "$INNER_APP/Contents/Resources/app.asar" ]]; then
  "$PYTHON_BIN" "$ROOT/scripts/patch_asar_icon.py" \
    --asar "$INNER_APP/Contents/Resources/app.asar" \
    --icon "$ASAR_ICON_SOURCE"
fi

/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.google.antigravity.proxy.inner' "$INNER_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $PROXY_ICON_NAME" "$INNER_APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $PROXY_ICON_NAME" "$INNER_APP/Contents/Info.plist"

set_helper_icon_and_id() {
  local helper_name="$1"
  local helper_id="$2"
  HELPER_APP="$INNER_APP/Contents/Frameworks/$helper_name"
  HELPER_PLIST="$HELPER_APP/Contents/Info.plist"
  if [[ -f "$HELPER_PLIST" ]]; then
    mkdir -p "$HELPER_APP/Contents/Resources"
    cp "$PROXY_ICON_PATH" "$HELPER_APP/Contents/Resources/$PROXY_ICON_NAME"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $helper_id" "$HELPER_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $PROXY_ICON_NAME" "$HELPER_PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $PROXY_ICON_NAME" "$HELPER_PLIST"
  fi
}

set_helper_icon_and_id "Antigravity Helper.app" "com.google.antigravity.proxy.inner.helper"
set_helper_icon_and_id "Antigravity Helper (GPU).app" "com.google.antigravity.proxy.inner.helper.GPU"
set_helper_icon_and_id "Antigravity Helper (Plugin).app" "com.google.antigravity.proxy.inner.helper.Plugin"
set_helper_icon_and_id "Antigravity Helper (Renderer).app" "com.google.antigravity.proxy.inner.helper.Renderer"

cat >"$DEST_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Antigravity-Proxy</string>
  <key>CFBundleExecutable</key>
  <string>AntigravityProxyLauncher</string>
  <key>CFBundleIdentifier</key>
  <string>com.google.antigravity.proxy</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Antigravity-Proxy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
EOF

if [[ -f "$PROXY_ICON_PATH" ]]; then
  cat >>"$DEST_APP/Contents/Info.plist" <<EOF
  <key>CFBundleIconFile</key>
  <string>$PROXY_ICON_NAME</string>
EOF
fi

cat >>"$DEST_APP/Contents/Info.plist" <<'EOF'
</dict>
</plist>
EOF

echo "APPL????" >"$DEST_APP/Contents/PkgInfo"

ENTITLEMENTS="$ROOT/build/antigravity-proxy.entitlements.plist"
cat >"$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <true/>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.device.camera</key>
  <true/>
</dict>
</plist>
EOF

echo "Removing quarantine attributes if present..."
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "Ad-hoc signing nested executables with DYLD injection entitlements..."
while IFS= read -r -d '' item; do
  if file "$item" | grep -q 'Mach-O'; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$item" >/dev/null 2>&1 || true
  fi
done < <(find "$DEST_APP/Contents" -type f -perm -111 -print0)

echo "Ad-hoc signing nested Antigravity app..."
codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS" "$INNER_APP"

echo "Ad-hoc signing app bundle with DYLD injection entitlements..."
codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS" "$DEST_APP"

echo "Verifying signature..."
codesign --verify --deep --strict "$DEST_APP"

echo "Prepared:"
echo "  $DEST_APP"
echo
echo "Entitlements:"
codesign -d --entitlements :- "$DEST_APP" 2>/dev/null || true
