#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Get Paper (PaperMC Fill API v3)
# ------------------------------------------------------------------------------
# Downloads the latest build with atomic writes, safe cleanup.
# ------------------------------------------------------------------------------

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_PATH="$(realpath "${SCRIPTS_DIR}")"

FILL_API="https://fill.papermc.io/v3"
MC_VERSION="26.2"

# ------------------------------------------------------------------------------
# Utilities & Helper Functions
# ------------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

_log() {
  local level="$1" color="$2"
  shift 2
  printf '[%s %b%s%b] [%s]: %s\n' \
    "$(date '+%H:%M:%S')" \
    "$color" \
    "$level" \
    "$NC" \
    "${LOG_TAG:-update}" \
    "$*"
}

log_info() { _log INFO "$GREEN" "$@"; }
log_warn() { _log WARN "$YELLOW" "$@"; }
log_err() { _log ERROR "$RED" "$@" >&2; }

check_deps() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_err "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

_curl() {
  curl -fsSL \
    -H "User-Agent: Everest/3.0.0" \
    --retry 1 \
    --retry-delay 2 \
    --connect-timeout 4 \
    "$@"
}

curl_json() { _curl -H "Accept: application/json" -- "$1"; }
curl_download() { _curl -o "$2" -- "$1"; }

# shellcheck disable=SC2329
cleanup_jobs() {
  local pids
  pids="$(jobs -pr 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
  fi
}

# Pre-flight
check_deps jq curl

mkdir -p "$ROOT_PATH"

trap cleanup_jobs EXIT INT TERM

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

log_info "Starting engine updates (Fill API v3)..."

# Fetch version metadata
version_url="${FILL_API}/projects/paper/versions/${MC_VERSION}"
version_resp="$(curl_json "$version_url")" || {
  log_err "Failed to fetch version meta"
  exit 1
}

if jq -e '.ok == false' >/dev/null 2>&1 <<<"$version_resp"; then
  log_err "API error: $(jq -r '.message // "Unknown"' <<<"$version_resp")"
  exit 1
fi

# Find latest build
latest_build="$(jq -r '.builds | max // empty' <<<"$version_resp")"

if [[ -z "$latest_build" || "$latest_build" == "null" ]]; then
  log_err "No builds found for ${MC_VERSION}."
  exit 1 
fi

# Fetch build detail
build_url="${FILL_API}/projects/paper/versions/${MC_VERSION}/builds/${latest_build}"
build_resp="$(curl_json "$build_url")" || {
  log_err "Failed to fetch build detail: #${latest_build}"
  exit 1
}

if jq -e '.ok == false' >/dev/null 2>&1 <<<"$build_resp"; then
  log_err "API error for #${latest_build}: $(jq -r '.message // "Unknown"' <<<"$build_resp")"
  exit 1
fi

dl_url="$(jq -r '.downloads."server:default".url // empty' <<<"$build_resp")"
dl_name="$(jq -r '.downloads."server:default".name // empty' <<<"$build_resp")"

[[ -n "$dl_url" ]] || {
  log_warn "No download URL for paper ${MC_VERSION}."
  exit 1
}
[[ -n "$dl_name" && "$dl_name" != "null" ]] || dl_name="${dl_url##*/}"

# Up-to-date check
target="${ROOT_PATH}/${dl_name}"
if [[ -f "$target" ]]; then
  log_info "Up-to-date ${dl_name} with latest build #${latest_build}"
  exit 0
fi

# Download (atomic)
tmp="${target}.tmp.$$"
log_info "Downloading ${dl_name}..."

if curl_download "$dl_url" "$tmp"; then
  mv -f "$tmp" "$target"
  log_info "Downloaded ${dl_name}."
else
  rm -f "$tmp"
  log_err "Download failed paper ${MC_VERSION}."
  exit 1
fi

# Cleanup old builds for same engine+version
removed=0
shopt -s nullglob
for f in "${ROOT_PATH}/paper-${MC_VERSION}-"*.jar; do
  [[ "$(basename "$f")" == "$dl_name" ]] && continue
  rm -f "$f"
  ((removed++)) || true
done

shopt -u nullglob
[[ $removed -gt 0 ]] && log_warn "Removed ${removed} old build(s) for ${MC_VERSION}"

exit 0
