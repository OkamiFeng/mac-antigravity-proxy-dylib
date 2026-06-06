#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$ROOT/Antigravity-Proxy.app"
PROXY_URL="socks5://127.0.0.1:7890"
ENV_PROXY_URL=""
LOG=1
TIMEOUT_MS=15000

usage() {
  cat <<'EOF'
Usage:
  ./launch-antigravity-proxy.sh [options] [-- antigravity-args]

Options:
  --app PATH             Prepared Antigravity app copy. Default: ./Antigravity-Proxy.app
  --proxy URL            SOCKS5 proxy URL. Default: socks5://127.0.0.1:7890
  --env-proxy URL        Proxy URL for HTTP_PROXY/HTTPS_PROXY/ALL_PROXY.
                         Default: http://same-host-and-port-as --proxy
  --quiet                Disable dylib debug logs.
  --timeout-ms N         SOCKS5 connect/read/write timeout. Default: 15000
  --dry-run              Print launch environment and exit.
  -h, --help             Show this help.
EOF
}

DRY_RUN=0
EXTRA_ARGS=()
while (($#)); do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "Missing --app value" >&2; exit 2; }
      APP_PATH="$2"
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
    --quiet)
      LOG=0
      shift
      ;;
    --timeout-ms)
      [[ $# -ge 2 ]] || { echo "Missing --timeout-ms value" >&2; exit 2; }
      TIMEOUT_MS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

DYLIB="$ROOT/build/libantigravity_proxy.dylib"
if [[ ! -f "$DYLIB" ]]; then
  "$ROOT/build.sh"
fi

[[ -d "$APP_PATH" ]] || {
  echo "Prepared app not found: $APP_PATH" >&2
  echo "Run ./prepare-app-copy.sh first." >&2
  exit 1
}

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo Antigravity)"
EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || { echo "Executable not found: $EXECUTABLE" >&2; exit 1; }

if [[ -z "$ENV_PROXY_URL" ]]; then
  PROXY_SCHEME="${PROXY_URL%%://*}"
  PROXY_HOST_PORT="${PROXY_URL#*://}"
  PROXY_HOST_PORT="${PROXY_HOST_PORT%%/*}"
  PROXY_HOST_PORT="${PROXY_HOST_PORT##*@}"
  if [[ "$PROXY_SCHEME" == "socks5" && "$PROXY_HOST_PORT" == *":7890" ]]; then
    ENV_PROXY_URL="http://$PROXY_HOST_PORT"
  else
    ENV_PROXY_URL="$PROXY_URL"
  fi
fi

export AG_PROXY="$PROXY_URL"
export AG_PROXY_LOG="$LOG"
export AG_PROXY_TIMEOUT_MS="$TIMEOUT_MS"
export DYLD_INSERT_LIBRARIES="$DYLIB"
export HTTP_PROXY="$ENV_PROXY_URL"
export HTTPS_PROXY="$ENV_PROXY_URL"
export ALL_PROXY="$ENV_PROXY_URL"
export http_proxy="$ENV_PROXY_URL"
export https_proxy="$ENV_PROXY_URL"
export all_proxy="$ENV_PROXY_URL"
export NO_PROXY="localhost,127.0.0.1,::1,*.local"
export no_proxy="$NO_PROXY"

echo "App: $APP_PATH"
echo "Executable: $EXECUTABLE"
echo "Dylib: $DYLIB"
echo "Proxy: $AG_PROXY"
echo "Env proxy: $ENV_PROXY_URL"
echo "Log: $AG_PROXY_LOG"

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

exec "$EXECUTABLE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
