#!/usr/bin/env bash
# Safety net for CI runs that get killed before destroy-test-env.sh runs
# (OOM, hard runner kill, etc.). Deletes any Konnect control plane tagged
# managed-by=ephemeral-test-cp whose ttl label has passed.
#
# Intended to run on a schedule (nightly CI job / cron), independent of the
# create/destroy flow.
#
# Usage:
#   ./reap-stale-envs.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./konnect-lib.sh
source "${SCRIPT_DIR}/konnect-lib.sh"

DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 1 ;;
    *) log_error "unknown argument: $1"; exit 1 ;;
  esac
done
export DRY_RUN

require_env

log_info "Listing control planes labeled ${EPHEMERAL_LABEL_KEY}=${EPHEMERAL_LABEL_VALUE}..."
# NOTE: verify this label-filter query param against your Konnect API
# version — paginate if you're running enough ephemeral CPs to exceed one
# page (default page size varies by API version).
CPS=$(konnect_api GET "/v2/control-planes?labels=${EPHEMERAL_LABEL_KEY}:${EPHEMERAL_LABEL_VALUE}" || echo '{"data":[]}')

NOW=$(date +%s)
REAPED=0
FAILED=0
SKIPPED=0

# NOTE: process substitution, not a pipe — a pipe would run this loop in a
# subshell and silently discard the REAPED/FAILED/SKIPPED counters below.
while read -r cp; do
  NAME=$(echo "$cp" | jq -r '.name')
  ID=$(echo "$cp" | jq -r '.id')
  TTL=$(echo "$cp" | jq -r '.labels.ttl // empty')

  if [[ -z "$TTL" ]]; then
    log_info "skipping '${NAME}' (id=${ID}) — no ttl label"
    continue
  fi

  if [[ "$TTL" -lt "$NOW" ]]; then
    AGE_HOURS=$(( (NOW - TTL) / 3600 ))
    log_info "reaping '${NAME}' (id=${ID}) — ${AGE_HOURS}h past ttl"
    if konnect_api DELETE "/v2/control-planes/${ID}" >/dev/null; then
      REAPED=$((REAPED + 1))
    else
      log_error "failed to delete '${NAME}' (id=${ID})"
      FAILED=$((FAILED + 1))
    fi
  else
    SKIPPED=$((SKIPPED + 1))
  fi
done < <(echo "$CPS" | jq -c '.data[]?')

log_info "Reap complete: ${REAPED} deleted, ${FAILED} failed, ${SKIPPED} still within ttl."
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
