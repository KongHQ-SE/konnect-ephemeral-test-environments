# Ephemeral Kong Konnect Test Environments

Reference scripts for spinning up an isolated, licensed Kong control plane +
connected data plane per developer/PR — for white-box/integration testing
without touching live QA or requiring a standalone Kong license (Konnect
pushes entitlements to the data plane automatically once it connects).

Built for teams on Konnect SaaS who need deterministic, parallel-safe test
environments in CI/CD instead of sharing one long-lived environment or
running an unlicensed local Kong container.

## Quick start

```bash
export KONNECT_TOKEN="kpat_xxxxxxxxxxxxxxxx"
./scripts/create-test-env.sh --name my-env --dry-run   # preview, no changes
./scripts/create-test-env.sh --name my-env             # for real
source .env.my-env
./scripts/destroy-test-env.sh --name my-env
```

**Start with `runbook.md`** for the full step-by-step (manual + CI/CD pipeline integration).

## Contents

| File | Purpose |
|---|---|
| `scripts/konnect-lib.sh` | Shared Konnect API / logging helpers, sourced by the others |
| `scripts/create-test-env.sh` | Provisions one ephemeral control plane + connected data plane |
| `scripts/destroy-test-env.sh` | Tears one down (idempotent) |
| `scripts/reap-stale-envs.sh` | Scheduled backstop: deletes any tagged environment past its TTL |
| `runbook.md` | Step-by-step manual + pipeline walkthrough |

## Prerequisites

`curl`, `jq`, `openssl`, `docker`; `deck` if you use `--config` to push
declarative config into the environment. A Konnect Personal Access Token
with control-plane create/delete permission, exported as `KONNECT_TOKEN`.

## Verify before first real run

**These scripts have not been executed against a live Konnect org.** Three
spots are flagged inline with `NOTE:` comments because the exact Konnect API
shape has shifted across releases and should be double-checked against your
org's API version before relying on this in CI:

- `create-test-env.sh` / `destroy-test-env.sh`: the `dp-client-certificates` endpoint used to register the data plane's certificate
- `create-test-env.sh`: the `/v2/control-planes/{id}/nodes` endpoint used to poll for data-plane-connected status
- `destroy-test-env.sh` / `reap-stale-envs.sh`: the control-plane list/filter query params used to look CPs up by name and by label

Treat the first real run as a validation run (see `runbook.md` § Manual
walkthrough), not a straight CI cutover. Everything else (control flow,
error handling, teardown-on-failure, TTL math) was smoke-tested locally
with `--dry-run`.

## Known issues

- Konnect API endpoint paths above are unverified against a live org — see "Verify before first real run"
- `--config` sync via `deck gateway sync` assumes decK's native `--konnect-*` flags are available in your `deck` version; older `deck` versions may need the Admin-API-proxy sync pattern instead
- No automated test suite for the scripts themselves (they're infra glue, not application code) — verification is `--dry-run` review + the manual runbook walkthrough
- `reap-stale-envs.sh` relies on the `ttl` label set at creation time; a control plane created any other way (manually in the UI, or by a different script) won't be reaped even if tagged `managed-by=ephemeral-test-cp`, unless it also has a `ttl` label
