#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

CC="${CC:-clang}"
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

printf 'Built:\n'
printf '  %s\n' "$BUILD_DIR/libantigravity_proxy.dylib"
printf '  %s\n' "$BUILD_DIR/test_client"
printf '  %s\n' "$BUILD_DIR/AntigravityProxyLauncher"
