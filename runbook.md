# Runbook: Ephemeral Kong Konnect Test Environments

This walks through using `scripts/create-test-env.sh`, `destroy-test-env.sh`,
and `reap-stale-envs.sh` — both by hand and from a CI pipeline — to give
each developer/PR an isolated, licensed Kong control plane + data plane for
white-box testing, without touching live QA or a standalone license.

See `README.md` for prerequisites and known limitations — **read the
"Verify before first real run" note there before running this against a
live Konnect org.**

---

## 1. Prerequisites

Install on whatever machine (laptop or CI runner) will run the scripts:

- `curl`, `jq`, `openssl` — usually already present
- `docker` — to run the data plane container
- [`deck`](https://developer.konghq.com/deck/) — only needed if you pass `--config` to push declarative config into the environment

Get a Konnect Personal Access Token (Konnect UI → your profile → Personal
Access Tokens) with permission to create/delete control planes in the org,
and export it:

```bash
export KONNECT_TOKEN="kpat_xxxxxxxxxxxxxxxx"
```

Optional overrides (defaults shown):

```bash
export KONNECT_API_URL="https://us.api.konghq.com"   # use eu.api.konghq.com if your org is EU-region
export CP_TTL_HOURS=4                                  # how long before reap-stale-envs.sh considers a CP abandoned
```

---

## 2. Manual walkthrough

Run this once by hand before wiring it into CI, to confirm it works against
your org.

1. **Create the environment:**

   ```bash
   cd scripts
   ./create-test-env.sh --name dev-yourname-manual-test
   ```

   Watch the log output — it creates the control plane, registers a data
   plane client certificate, starts a `kong/kong-gateway` container in
   hybrid data-plane mode, and waits for it to connect.

2. **Verify in the Konnect UI:**
   - Gateway Manager → Control Planes → you should see `dev-yourname-manual-test` with the labels `managed-by=ephemeral-test-cp` and a `ttl` timestamp
   - Open it → the data plane node should show as connected

3. **Check the connection file:**

   ```bash
   cat .env.dev-yourname-manual-test
   ```

   This has the control plane id, endpoint, container name, and local proxy
   URL. Source it in your test suite:

   ```bash
   source .env.dev-yourname-manual-test
   curl "$KONG_TEST_PROXY_URL/"
   ```

4. **Run your white-box/integration tests** against the control plane's
   Admin API (via Konnect) or the proxy URL from the env file.

5. **Tear it down:**

   ```bash
   ./destroy-test-env.sh --name dev-yourname-manual-test
   ```

   Confirm in the Konnect UI that the control plane is gone and that the
   `kong-dp-dev-yourname-manual-test` container no longer exists (`docker ps -a`).

If you want to preview every command without touching your org first, add
`--dry-run` to either script — it prints the exact `curl`/`docker`/`deck`
commands instead of running them.

---

## 3. Pipeline integration

Two properties matter for CI:

- **Uniqueness per run** — pass a `--name` that's unique per concurrent job (PR number + run id is a good combination), so parallel developers/PRs never collide
- **Teardown always runs** — put `destroy-test-env.sh` in an "always run"
  step so a failing test suite doesn't leak the control plane

### Example: GitHub Actions

```yaml
name: integration-tests
on: [pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    env:
      KONNECT_TOKEN: ${{ secrets.KONNECT_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      - name: Set env id
        run: echo "ENV_NAME=pr-${{ github.event.number }}-${{ github.run_id }}" >> "$GITHUB_ENV"

      - name: Create ephemeral test environment
        run: ./scripts/create-test-env.sh --name "$ENV_NAME" --config kong.yaml

      - name: Run integration tests
        run: |
          source ".env.${ENV_NAME}"
          ./run-your-tests.sh   # replace with your actual test command

      - name: Destroy ephemeral test environment
        if: always()
        run: ./scripts/destroy-test-env.sh --name "$ENV_NAME"
```

The same shape applies to Jenkins/GitLab CI/etc. — the two load-bearing
requirements are "unique `--name` per run" and "`destroy-test-env.sh` in a
step that runs regardless of test outcome" (`post { always { ... } }` in
Jenkins, `when: always` in GitLab).

### Scheduling the reaper

Run `reap-stale-envs.sh` on a schedule, independent of the test pipeline
above — it's the backstop for runs where the "always run" teardown step
itself never executed (runner OOM-killed, hard-killed job, etc.).

```yaml
name: reap-stale-test-environments
on:
  schedule:
    - cron: "0 * * * *"   # hourly
  workflow_dispatch: {}

jobs:
  reap:
    runs-on: ubuntu-latest
    env:
      KONNECT_TOKEN: ${{ secrets.KONNECT_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/reap-stale-envs.sh
```

Cron/Jenkins-scheduled-job equivalents: same command, run hourly or nightly
depending on how quickly you want abandoned CPs reclaimed relative to
`CP_TTL_HOURS`.

---

## 4. Troubleshooting

**`create-test-env.sh` fails at "Waiting for data plane to report connected"**
- Check `docker logs kong-dp-<name>` for TLS/connection errors
- Confirm the CP endpoint and cert were registered correctly — rerun with `--dry-run` to inspect the exact API calls
- The polling endpoint (`/v2/control-planes/{id}/nodes`) is flagged in the script as needing verification against your org's Konnect API version — if this consistently times out but the DP looks healthy in the Konnect UI, the endpoint/field name likely needs adjusting

**Control plane creation fails with a 4xx about limits**
- Your org may be at or near Konnect's soft control-plane limit (~200-300, raisable on request) — check `reap-stale-envs.sh` is actually running on schedule, and ask your Kong account team to raise the limit if you're legitimately running that many concurrent environments

**A `.env.<name>` file exists but nothing is running**
- A prior run likely failed before writing the file, or teardown didn't fully complete — `destroy-test-env.sh --name <name>` is idempotent and safe to rerun; it will clean up whatever's left

**Two runs collide on the same control plane name**
- The `--name` you pass isn't unique enough for your CI's concurrency — include the CI run id, not just the PR number, if the same PR can trigger overlapping runs (e.g. force-pushes re-triggering CI before the prior run's teardown finished)
