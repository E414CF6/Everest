#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Everest - PaperMC Server Updater (Fill API v3)
# ------------------------------------------------------------------------------
# Automatically checks, downloads, verifies, and updates PaperMC builds.
# ------------------------------------------------------------------------------

PROJECT="paper"
MC_VERSION="${MC_VERSION:-26.2}"
FILL_API="https://fill.papermc.io/v3"

SERVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
USER_AGENT="Everest/3.0"

# ------------------------------------------------------------------------------
# Logging & Utilities
# ------------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;34m'
  C_GRAY=$'\033[0;90m'
else
  C_RESET=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_GRAY=''
fi

log_info() {
  printf '%s[%s]%s %s[INFO]%s  %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_BLUE" "$C_RESET" "$*"
}

log_success() {
  printf '%s[%s]%s %s[OK]%s    %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"
}

log_warn() {
  printf '%s[%s]%s %s[WARN]%s  %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*"
}

log_error() {
  printf '%s[%s]%s %s[ERROR]%s %s\n' "$C_GRAY" "$(date '+%H:%M:%S')" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2
}

check_dependencies() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing[*]}"
    exit 1
  fi
}

api_get() {
  curl -fsSL \
    -H "User-Agent: ${USER_AGENT}" \
    -H "Accept: application/json" \
    --connect-timeout 5 \
    --retry 2 \
    --retry-delay 1 \
    "$1"
}

download_file() {
  local url="$1" dest="$2"
  if [[ -t 1 ]]; then
    curl -fL \
      -H "User-Agent: ${USER_AGENT}" \
      --connect-timeout 10 \
      --retry 3 \
      --retry-delay 2 \
      --progress-bar \
      -o "$dest" \
      "$url"
  else
    curl -fsSL \
      -H "User-Agent: ${USER_AGENT}" \
      --connect-timeout 10 \
      --retry 3 \
      --retry-delay 2 \
      -o "$dest" \
      "$url"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

check_dependencies curl jq sha256sum

log_info "Checking updates for ${PROJECT} (MC: ${MC_VERSION})..."

# 1. Fetch version metadata & latest build number
version_url="${FILL_API}/projects/${PROJECT}/versions/${MC_VERSION}"
if ! version_json="$(api_get "$version_url")"; then
  log_error "Failed to fetch version metadata for ${PROJECT} ${MC_VERSION}"
  exit 1
fi

latest_build="$(jq -r '.builds | max // empty' <<<"$version_json")"
if [[ -z "$latest_build" || "$latest_build" == "null" ]]; then
  log_error "No available builds found for ${PROJECT} ${MC_VERSION}."
  exit 1
fi

# 2. Fetch build details
build_url="${FILL_API}/projects/${PROJECT}/versions/${MC_VERSION}/builds/${latest_build}"
if ! build_json="$(api_get "$build_url")"; then
  log_error "Failed to fetch details for build #${latest_build}"
  exit 1
fi

dl_name="$(jq -r '.downloads["server:default"].name // empty' <<<"$build_json")"
dl_url="$(jq -r '.downloads["server:default"].url // empty' <<<"$build_json")"
dl_sha256="$(jq -r '.downloads["server:default"].checksums.sha256 // empty' <<<"$build_json")"

if [[ -z "$dl_url" ]]; then
  log_error "Download URL not found in build #${latest_build} metadata."
  exit 1
fi

[[ -z "$dl_name" ]] && dl_name="${PROJECT}-${MC_VERSION}-${latest_build}.jar"
target_file="${SERVER_DIR}/${dl_name}"

# 3. Check if already up-to-date
if [[ -f "$target_file" ]]; then
  log_success "Server is up-to-date (${dl_name} - Build #${latest_build})"
  exit 0
fi

# 4. Download and verify
tmp_file="${target_file}.tmp.$$"
trap 'rm -f "$tmp_file"' EXIT INT TERM

log_info "Downloading ${dl_name} (Build #${latest_build})..."
if ! download_file "$dl_url" "$tmp_file"; then
  log_error "Download failed for ${dl_name}"
  exit 1
fi

# Checksum verification
if [[ -n "$dl_sha256" ]]; then
  log_info "Verifying SHA-256 checksum..."
  file_sha256="$(sha256sum "$tmp_file" | awk '{print $1}')"
  if [[ "$file_sha256" != "$dl_sha256" ]]; then
    log_error "Checksum verification failed!"
    log_error "Expected: ${dl_sha256}"
    log_error "Actual:   ${file_sha256}"
    exit 1
  fi
  log_success "Checksum verified."
fi

# Atomic move
mv -f "$tmp_file" "$target_file"
trap - EXIT INT TERM
log_success "Successfully installed ${dl_name}!"

# 5. Clean up older builds
removed_count=0
shopt -s nullglob
for old_jar in "${SERVER_DIR}/${PROJECT}-${MC_VERSION}-"*.jar; do
  if [[ "$old_jar" != "$target_file" ]]; then
    rm -f "$old_jar"
    ((removed_count++)) || true
  fi
done
shopt -u nullglob

if [[ $removed_count -gt 0 ]]; then
  log_info "Cleaned up ${removed_count} old build(s)."
fi

exit 0
