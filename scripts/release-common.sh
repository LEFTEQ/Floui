#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_release_env() {
  local config_file="$1"
  if [[ -z "$config_file" ]]; then
    return
  fi

  if [[ ! -f "$config_file" ]]; then
    echo "Release config not found: $config_file" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$config_file"
}

ensure_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
}

require_var() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing required environment variable: $variable_name" >&2
    exit 1
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

plist_bool_tag() {
  local value="${1:-NO}"
  local upper
  upper="$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    YES|TRUE|1)
      printf '<true/>'
      ;;
    *)
      printf '<false/>'
      ;;
  esac
}

resolve_release_version() {
  require_var FLOUI_RELEASE_VERSION
  printf '%s' "$FLOUI_RELEASE_VERSION"
}

resolve_build_number() {
  if [[ -n "${FLOUI_BUILD_NUMBER:-}" ]]; then
    printf '%s' "$FLOUI_BUILD_NUMBER"
    return
  fi

  date -u +%Y%m%d%H%M%S
}

resolve_app_name() {
  printf '%s' "${FLOUI_APP_NAME:-Floui}"
}

resolve_executable_name() {
  printf '%s' "${FLOUI_EXECUTABLE_NAME:-FlouiApp}"
}

default_release_output_dir() {
  local version
  version="$(resolve_release_version)"
  printf '%s/dist/release/%s' "$ROOT_DIR" "$version"
}

resolve_release_output_dir() {
  local requested_dir="$1"
  if [[ -n "$requested_dir" ]]; then
    printf '%s' "$requested_dir"
    return
  fi

  default_release_output_dir
}

resolve_release_binary_path() {
  local executable_name
  executable_name="$(resolve_executable_name)"

  if [[ -x "$ROOT_DIR/.build/arm64-apple-macosx/release/$executable_name" ]]; then
    printf '%s/.build/arm64-apple-macosx/release/%s' "$ROOT_DIR" "$executable_name"
    return
  fi

  if [[ -x "$ROOT_DIR/.build/release/$executable_name" ]]; then
    printf '%s/.build/release/%s' "$ROOT_DIR" "$executable_name"
    return
  fi

  if command -v swift >/dev/null 2>&1; then
    local bin_path
    bin_path="$(cd "$ROOT_DIR" && swift build -c release --show-bin-path)"
    if [[ -x "$bin_path/$executable_name" ]]; then
      printf '%s/%s' "$bin_path" "$executable_name"
      return
    fi
  fi

  echo "Unable to locate built release executable for $executable_name" >&2
  exit 1
}

write_info_plist() {
  local plist_path="$1"
  local release_version="$2"
  local build_number="$3"
  local app_name
  local executable_name
  local bundle_id
  local minimum_system_version
  local apple_events_usage_description
  local copyright_notice
  app_name="$(resolve_app_name)"
  executable_name="$(resolve_executable_name)"
  bundle_id="${FLOUI_BUNDLE_ID:-com.floui.app}"
  minimum_system_version="${FLOUI_MINIMUM_SYSTEM_VERSION:-15.0}"
  apple_events_usage_description="${FLOUI_APPLE_EVENTS_USAGE_DESCRIPTION:-Floui needs Automation access to arrange browser windows and developer tools for your workspaces.}"
  copyright_notice="${FLOUI_COPYRIGHT:-Copyright 2026 Floui}"

  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(xml_escape "$app_name")</string>
    <key>CFBundleExecutable</key>
    <string>$(xml_escape "$executable_name")</string>
    <key>CFBundleIdentifier</key>
    <string>$(xml_escape "$bundle_id")</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(xml_escape "$app_name")</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(xml_escape "$release_version")</string>
    <key>CFBundleVersion</key>
    <string>$(xml_escape "$build_number")</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(xml_escape "$minimum_system_version")</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>$(xml_escape "$apple_events_usage_description")</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>$(xml_escape "$copyright_notice")</string>
EOF

    if [[ -n "${FLOUI_APPCAST_URL:-}" ]]; then
      cat <<EOF
    <key>SUFeedURL</key>
    <string>$(xml_escape "$FLOUI_APPCAST_URL")</string>
EOF
    fi

    if [[ -n "${FLOUI_SUPUBLIC_ED_KEY:-}" ]]; then
      cat <<EOF
    <key>SUPublicEDKey</key>
    <string>$(xml_escape "$FLOUI_SUPUBLIC_ED_KEY")</string>
EOF
    fi

    cat <<EOF
    <key>SUEnableAutomaticChecks</key>
    $(plist_bool_tag "${FLOUI_SU_ENABLE_AUTOMATIC_CHECKS:-YES}")
    <key>SUScheduledCheckInterval</key>
    <integer>${FLOUI_SU_SCHEDULED_CHECK_INTERVAL:-86400}</integer>
    <key>SUAutomaticallyUpdate</key>
    $(plist_bool_tag "${FLOUI_SU_AUTOMATICALLY_UPDATE:-YES}")
    <key>SUAllowsAutomaticUpdates</key>
    $(plist_bool_tag "${FLOUI_SU_ALLOWS_AUTOMATIC_UPDATES:-YES}")
    <key>SUVerifyUpdateBeforeExtraction</key>
    $(plist_bool_tag "${FLOUI_SU_VERIFY_UPDATE_BEFORE_EXTRACTION:-YES}")
    <key>SURequireSignedFeed</key>
    $(plist_bool_tag "${FLOUI_SU_REQUIRE_SIGNED_FEED:-YES}")
</dict>
</plist>
EOF
  } >"$plist_path"
}

release_app_path() {
  local output_dir="$1"
  printf '%s/%s.app' "$output_dir" "$(resolve_app_name)"
}

release_zip_path() {
  local output_dir="$1"
  printf '%s/%s-%s.zip' "$output_dir" "$(resolve_app_name)" "$(resolve_release_version)"
}

print_release_summary() {
  local app_path="$1"
  local archive_path="${2:-}"
  echo "Prepared release bundle:"
  echo "  app: $app_path"
  if [[ -n "$archive_path" ]]; then
    echo "  archive: $archive_path"
  fi
}
