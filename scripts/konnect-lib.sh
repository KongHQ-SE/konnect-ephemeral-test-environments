#!/usr/bin/env bash
# Shared helpers for the ephemeral-test-environment scripts.
# Source this file — do not execute it directly.
#
# Required env: KONNECT_TOKEN
# Optional env: KONNECT_API_URL (default https://us.api.konghq.com)
#               CP_TTL_HOURS    (default 4)

: "${KONNECT_API_URL:=https://us.api.konghq.com}"
: "${CP_TTL_HOURS:=4}"
readonly EPHEMERAL_LABEL_KEY="managed-by"
readonly EPHEMERAL_LABEL_VALUE="ephemeral-test-cp"

log_info()  { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] INFO  %s\n' -1 "$*" >&2; }
log_error() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] ERROR %s\n' -1 "$*" >&2; }

require_env() {
  if [[ -z "${KONNECT_TOKEN:-}" ]]; then
    log_error "KONNECT_TOKEN is not set. Export a Konnect Personal Access Token before running this script."
    exit 1
  fi
  for bin in curl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      log_error "required binary '$bin' not found on PATH"
      exit 1
    fi
  done
}

# konnect_api METHOD PATH [JSON_BODY]
# Prints the response body on stdout. Exits non-zero on non-2xx.
konnect_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="${KONNECT_API_URL}${path}"
  local -a curl_args=(-sS -w '\n%{http_code}' -X "$method"
    -H "Authorization: Bearer ${KONNECT_TOKEN}"
    -H "Content-Type: application/json"
    "$url")
  if [[ -n "$body" ]]; then
    curl_args+=(-d "$body")
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[dry-run] curl ${method} ${url}${body:+ -d '$body'}"
    echo '{}'
    return 0
  fi

  local raw status response
  raw="$(curl "${curl_args[@]}")"
  status="${raw##*$'\n'}"
  response="${raw%$'\n'*}"

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    log_error "Konnect API ${method} ${path} returned HTTP ${status}: ${response}"
    return 1
  fi
  echo "$response"
}

# run_or_echo CMD... — executes, or just logs the command under --dry-run.
run_or_echo() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}
