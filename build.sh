#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

CC="${CC:-clang}"
SWIFTC="${SWIFTC:-swiftc}"
CFLAGS=(
  -O2
  -Wall
  -Wextra
  -Werror
  -Wno-deprecated-declarations
)

"$CC" "${CFLAGS[@]}" -dynamiclib \
  -o "$BUILD_DIR/libantigravity_proxy.dylib" \
  "$ROOT/src/antigravity_proxy.c"

"$CC" "${CFLAGS[@]}" \
  -o "$BUILD_DIR/test_client" \
  "$ROOT/tests/test_client.c"

"$CC" "${CFLAGS[@]}" \
  -o "$BUILD_DIR/AntigravityProxyLauncher" \
  "$ROOT/src/launcher.c"

if command -v "$SWIFTC" >/dev/null 2>&1; then
  "$SWIFTC" -parse-as-library -O \
    -o "$BUILD_DIR/AntigravityProxyBuilder" \
    "$ROOT/src/BuilderApp.swift"

  APP_DIR="$BUILD_DIR/Antigravity-Proxy.app"
  APP_CONTENTS="$APP_DIR/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  rm -rf "$APP_DIR"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"

  cp "$BUILD_DIR/AntigravityProxyBuilder" "$APP_MACOS/AntigravityProxyBuilder"
  cp "$BUILD_DIR/AntigravityProxyLauncher" "$APP_RESOURCES/AntigravityProxyLauncher"
  cp "$BUILD_DIR/libantigravity_proxy.dylib" "$APP_RESOURCES/libantigravity_proxy.dylib"
  cp "$ROOT/icon.png" "$APP_RESOURCES/icon.png"

  ICONSET="$BUILD_DIR/antigravity-proxy.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ROOT/icon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ROOT/icon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ROOT/icon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ROOT/icon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ROOT/icon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ROOT/icon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ROOT/icon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ROOT/icon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ROOT/icon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ROOT/icon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/antigravity-proxy.icns"
  rm -rf "$ICONSET"

  cat >"$APP_CONTENTS/Info.plist" <<'EOF'
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
  <string>AntigravityProxyBuilder</string>
  <key>CFBundleIdentifier</key>
  <string>com.okamifeng.antigravity-proxy.builder</string>
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
  <key>CFBundleIconFile</key>
  <string>antigravity-proxy.icns</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
</dict>
</plist>
EOF
  echo "APPL????" >"$APP_CONTENTS/PkgInfo"
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

printf 'Built:\n'
printf '  %s\n' "$BUILD_DIR/libantigravity_proxy.dylib"
printf '  %s\n' "$BUILD_DIR/test_client"
printf '  %s\n' "$BUILD_DIR/AntigravityProxyLauncher"
if [[ -d "$BUILD_DIR/Antigravity-Proxy.app" ]]; then
  printf '  %s\n' "$BUILD_DIR/Antigravity-Proxy.app"
fi
