#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT/Antigravity-Proxy.app"

patterns=(
  "$APP_PATH/Contents/MacOS/AntigravityProxyLauncher"
  "$APP_PATH/Contents/Resources/Antigravity.app"
)

found=0
for pattern in "${patterns[@]}"; do
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    found=1
    kill "$pid" 2>/dev/null || true
  done < <(pgrep -f "$pattern" || true)
done

if [[ "$found" -eq 0 ]]; then
  echo "Antigravity Proxy is not running."
  exit 0
fi

sleep 2

for pattern in "${patterns[@]}"; do
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(pgrep -f "$pattern" || true)
done

echo "Antigravity Proxy stopped."
