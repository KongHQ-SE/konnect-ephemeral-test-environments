# Decision Log

Append-only. Reversed decisions get a new entry linking back — originals are never edited or deleted.

---

## 2026-08-18 — Repo scoped as a generic reference, not customer-named

**Decision:** This repo contains only the generic scripts, runbook, and
README for the ephemeral-Konnect-environment pattern. It excludes the
customer-specific design spec, deck config, and internal meeting notes that
motivated the work.

**Rationale:** The scripts were originally built in response to a specific
customer's requirement. Two things made a customer-scoped repo the wrong
default: (1) the KongHQ-SE GitHub org blocks members from creating public
repos (`members_can_create_public_repositories: false`), so "public" wasn't
actually available regardless; (2) the customer-specific artifacts named the
account, quoted internal meeting notes, and referenced Kong staff by name —
none of which belongs in a repo meant to be broadly reusable across SEs and
customers, private or not. Keeping the repo customer-agnostic means it can
later go public (once an org admin enables that setting) without a rewrite.

**Scope:** Applies to this repo only. The customer-specific design doc and
config remain in that customer's private working directory, not here.

**Links:** N/A — no visual companion or separate spec file for this
decision; captured directly from the working session.
