#!/usr/bin/env bash
# Provision one ephemeral Kong Konnect control plane + connected data plane
# for white-box/integration testing.
#
# Usage:
#   ./create-test-env.sh --name <env-id> [--config <deck-state.yaml>] [--dry-run]
#
# --name is required. The caller decides the identifier scheme (e.g. a CI
# pipeline might pass "pr-482-a1b2c3"; a developer running this locally might
# pass their own name). It must be unique per concurrent environment.
#
# On success, writes .env.<name> to the current directory with connection
# details for the test suite to source.
#
# Requires: curl, jq, openssl, docker, deck (only if --config is passed)
# Required env: KONNECT_TOKEN
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./konnect-lib.sh
source "${SCRIPT_DIR}/konnect-lib.sh"

ENV_NAME=""
DECK_CONFIG=""
DRY_RUN="false"
KONG_IMAGE="${KONG_IMAGE:-kong/kong-gateway:3.9}"

usage() {
  echo "Usage: $0 --name <env-id> [--config <deck-state.yaml>] [--dry-run]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) ENV_NAME="$2"; shift 2 ;;
    --config) DECK_CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage ;;
    *) log_error "unknown argument: $1"; usage ;;
  esac
done
export DRY_RUN

[[ -n "$ENV_NAME" ]] || usage
require_env

if [[ -n "$DECK_CONFIG" ]] && ! command -v deck >/dev/null 2>&1; then
  log_error "--config was passed but 'deck' is not on PATH"
  exit 1
fi

# Fixed, name-keyed path (not mktemp) so destroy-test-env.sh can find and
# remove it later — it must survive for the container's whole lifetime,
# since it's bind-mounted into the running data plane, not copied in.
CERT_DIR="/tmp/kong-dp-certs/${ENV_NAME}"
mkdir -p "$CERT_DIR"
CP_ID=""
DP_CONTAINER="kong-dp-${ENV_NAME}"

# Best-effort teardown if anything fails after the control plane exists.
# destroy-test-env.sh is responsible for removing CERT_DIR too — do not rm
# it here, since a failure that happens *after* `docker run` would delete
# the live bind mount out from under the still-running container.
cleanup_on_failure() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log_error "create-test-env failed (exit ${exit_code}) — attempting cleanup of '${ENV_NAME}'"
    "${SCRIPT_DIR}/destroy-test-env.sh" --name "$ENV_NAME" || true
  fi
}
trap cleanup_on_failure EXIT

log_info "Creating control plane '${ENV_NAME}'..."
TTL_EPOCH=$(( $(date +%s) + CP_TTL_HOURS * 3600 ))
CREATE_BODY=$(jq -n \
  --arg name "$ENV_NAME" \
  --arg mby "$EPHEMERAL_LABEL_KEY" \
  --arg mbv "$EPHEMERAL_LABEL_VALUE" \
  --arg ttl "$TTL_EPOCH" \
  '{
    name: $name,
    description: "Ephemeral test environment (auto-created)",
    cluster_type: "CLUSTER_TYPE_CONTROL_PLANE",
    auth_type: "pinned_client_certs",
    labels: { (($mby)): $mbv, "ttl": $ttl, "source": $name }
  }')
CP_RESPONSE=$(konnect_api POST "/v2/control-planes" "$CREATE_BODY")
CP_ID=$(echo "$CP_RESPONSE" | jq -r '.id // "dry-run-cp-id"')
CP_ENDPOINT=$(echo "$CP_RESPONSE" | jq -r '.config.control_plane_endpoint // "dry-run-cp-endpoint"')
TELEMETRY_ENDPOINT=$(echo "$CP_RESPONSE" | jq -r '.config.telemetry_endpoint // "dry-run-telemetry-endpoint"')
log_info "Control plane created: id=${CP_ID} endpoint=${CP_ENDPOINT}"

# NOTE: verify this endpoint path against the Konnect API version your
# org is on — the dp-client-certificates route has moved across Konnect API
# releases. We generate the keypair locally and only ever send the PUBLIC
# certificate to Konnect; the private key stays on this host / mounted into
# the data plane container.
log_info "Generating data plane client certificate..."
run_or_echo openssl req -new -x509 -nodes \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "${CERT_DIR}/dp.key" -out "${CERT_DIR}/dp.crt" \
  -days 1 -subj "/CN=${ENV_NAME}"

if [[ "$DRY_RUN" != "true" ]]; then
  DP_CERT_PEM=$(cat "${CERT_DIR}/dp.crt")
  CERT_BODY=$(jq -n --arg cert "$DP_CERT_PEM" '{cert: $cert}')
  konnect_api POST "/v2/control-planes/${CP_ID}/dp-client-certificates" "$CERT_BODY" >/dev/null
fi
log_info "Data plane client certificate registered."

if [[ -n "$DECK_CONFIG" ]]; then
  log_info "Syncing declarative config '${DECK_CONFIG}' into '${ENV_NAME}'..."
  run_or_echo deck gateway sync \
    --konnect-token "$KONNECT_TOKEN" \
    --konnect-addr "$KONNECT_API_URL" \
    --konnect-control-plane-name "$ENV_NAME" \
    "$DECK_CONFIG"
fi

log_info "Starting data plane container '${DP_CONTAINER}'..."
run_or_echo docker run -d --name "$DP_CONTAINER" \
  -e "KONG_ROLE=data_plane" \
  -e "KONG_DATABASE=off" \
  -e "KONG_CLUSTER_MTLS=pki" \
  -e "KONG_CLUSTER_CONTROL_PLANE=${CP_ENDPOINT}:443" \
  -e "KONG_CLUSTER_SERVER_NAME=${CP_ENDPOINT}" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${TELEMETRY_ENDPOINT}:443" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${TELEMETRY_ENDPOINT}" \
  -e "KONG_CLUSTER_CERT=/etc/kong/dp.crt" \
  -e "KONG_CLUSTER_CERT_KEY=/etc/kong/dp.key" \
  -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
  -e "KONG_KONNECT_MODE=on" \
  -v "${CERT_DIR}:/etc/kong:ro" \
  -p 0:8000 -p 0:8443 \
  "$KONG_IMAGE"

if [[ "$DRY_RUN" != "true" ]]; then
  PROXY_PORT=$(docker port "$DP_CONTAINER" 8000/tcp | head -1 | cut -d: -f2)
else
  PROXY_PORT="dry-run-port"
fi

# NOTE: verify this poll endpoint against your Konnect API version —
# used /v2/control-planes/{id}/nodes here; confirm the exact path and the
# field that indicates a healthy/connected node before relying on it in CI.
log_info "Waiting for data plane to report connected..."
CONNECTED="false"
if [[ "$DRY_RUN" != "true" ]]; then
  for _ in $(seq 1 30); do
    NODES=$(konnect_api GET "/v2/control-planes/${CP_ID}/nodes" || echo '{"data":[]}')
    if echo "$NODES" | jq -e '.data[]? | select(.type == "KONG" and (.status // "") == "connected")' >/dev/null 2>&1; then
      CONNECTED="true"
      break
    fi
    sleep 2
  done
  if [[ "$CONNECTED" != "true" ]]; then
    log_error "data plane did not report connected within 60s — see runbook.md Troubleshooting"
    exit 1
  fi
else
  CONNECTED="true"
fi
log_info "Data plane connected."

ENV_FILE=".env.${ENV_NAME}"
cat > "$ENV_FILE" <<EOF
KONG_TEST_ENV_NAME=${ENV_NAME}
KONG_TEST_CP_ID=${CP_ID}
KONG_TEST_CP_ENDPOINT=${CP_ENDPOINT}
KONG_TEST_DP_CONTAINER=${DP_CONTAINER}
KONG_TEST_PROXY_URL=http://localhost:${PROXY_PORT}
EOF
log_info "Environment ready. Connection details written to ${ENV_FILE}"

trap - EXIT
