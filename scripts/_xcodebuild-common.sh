#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

resolve_scheme() {
  local list_output
  list_output="$(xcodebuild -list 2>/dev/null || true)"

  if grep -q "Floui-Package" <<<"$list_output"; then
    echo "Floui-Package"
    return
  fi

  if grep -q "Floui" <<<"$list_output"; then
    echo "Floui"
    return
  fi

  local first_scheme
  first_scheme="$(awk '/Schemes:/{flag=1;next} flag && NF{print $1; exit}' <<<"$list_output")"
  if [[ -n "$first_scheme" ]]; then
    echo "$first_scheme"
    return
  fi

  echo "Unable to resolve xcodebuild scheme" >&2
  exit 1
}

run_tests() {
  local scheme="$1"
  shift

  xcodebuild test \
    -scheme "$scheme" \
    -destination "platform=macOS" \
    "$@"
}
