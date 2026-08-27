#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Apple Core"
BUNDLE_ID="com.oliverames.applecore"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  xcodebuild -quiet \
    -project "$ROOT_DIR/Apple Core.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
}

open_app() {
  local open_arguments=(-n)
  if [[ -n "${APPLECORE_CONFIG_HOME:+set}" ]]; then
    open_arguments+=(--env "APPLECORE_CONFIG_HOME=$APPLECORE_CONFIG_HOME")
  fi
  /usr/bin/open "${open_arguments[@]}" "$APP_BUNDLE"
}

fresh_app_is_running() {
  local command pid
  while IFS= read -r pid; do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$APP_BINARY" ]]; then
      return 0
    fi
  done < <(pgrep -x "$APP_NAME" || true)
  return 1
}

stop_running_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if fresh_app_is_running; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not launch from $APP_BUNDLE. Another installed copy may be running." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
