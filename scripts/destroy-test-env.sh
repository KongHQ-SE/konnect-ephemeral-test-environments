#!/usr/bin/env bash
# Tear down one ephemeral test environment created by create-test-env.sh.
# Idempotent: safe to call even if the environment was only partially
# created, or already torn down — a missing container/CP is not an error.
#
# Usage:
#   ./destroy-test-env.sh --name <env-id> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./konnect-lib.sh
source "${SCRIPT_DIR}/konnect-lib.sh"

ENV_NAME=""
DRY_RUN="false"

usage() {
  echo "Usage: $0 --name <env-id> [--dry-run]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) ENV_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage ;;
    *) log_error "unknown argument: $1"; usage ;;
  esac
done
export DRY_RUN

[[ -n "$ENV_NAME" ]] || usage
require_env

DP_CONTAINER="kong-dp-${ENV_NAME}"
CERT_DIR="/tmp/kong-dp-certs/${ENV_NAME}"
FAILED="false"

log_info "Stopping data plane container '${DP_CONTAINER}' (if running)..."
if docker inspect "$DP_CONTAINER" >/dev/null 2>&1; then
  run_or_echo docker rm -f "$DP_CONTAINER"
else
  log_info "no container named '${DP_CONTAINER}' — skipping"
fi

log_info "Looking up control plane '${ENV_NAME}'..."
# NOTE: filtering by name via query param — verify this list-and-filter
# pattern against your Konnect API version if it 404s/behaves
# differently than expected.
CP_LOOKUP=$(konnect_api GET "/v2/control-planes?filter%5Bname%5D%5Bcontains%5D=${ENV_NAME}" || echo '{"data":[]}')
CP_ID=$(echo "$CP_LOOKUP" | jq -r --arg name "$ENV_NAME" '.data[]? | select(.name == $name) | .id' | head -1)

if [[ -n "$CP_ID" && "$CP_ID" != "null" ]]; then
  log_info "Deleting control plane '${ENV_NAME}' (id=${CP_ID})..."
  if ! konnect_api DELETE "/v2/control-planes/${CP_ID}" >/dev/null; then
    log_error "failed to delete control plane '${ENV_NAME}' (id=${CP_ID})"
    FAILED="true"
  fi
else
  log_info "no control plane named '${ENV_NAME}' found — skipping"
fi

log_info "Removing local artifacts..."
run_or_echo rm -rf "$CERT_DIR"
run_or_echo rm -f ".env.${ENV_NAME}"

if [[ "$FAILED" == "true" ]]; then
  log_error "teardown of '${ENV_NAME}' completed with errors — see above"
  exit 1
fi
log_info "Teardown of '${ENV_NAME}' complete."
