# Cloudflare Deployment Operating Guide

- **Date:** 2026-07-16
- **Scope:** Cloudflare Workers deployed through the reusable
  `.github/workflows/cloudflare-deploy.yml` workflow in `yearn/yearn-gha`.
- **Canonical caller:** [`examples/price-service/deploy.yml`](../examples/price-service/deploy.yml).

## Contract

The reusable workflow is `workflow_call` only. A project provides a thin caller
with its vault name, app-secret references, and `OP_SERVICE_ACCOUNT_TOKEN`.

The workflow runs these steps in order:

1. Checkout the caller repository.
2. Set up pinned Bun and run `bun install --frozen-lockfile`.
3. Validate that `vault` is a project vault named `webops-prod-<project>`.
4. Resolve declared app-secret references from the project vault.
5. Load secrets from 1Password.
6. Bulk-upload declared Worker secrets with `bunx wrangler secret bulk`.
7. Run the project's `bun run deploy`.

The install runs before any secrets are loaded. The bulk upload and deploy are
separate Cloudflare mutations; a successful bulk followed by a failed deploy
can leave new runtime secrets on the previously deployed code.

## 1Password layout

Only `OP_SERVICE_ACCOUNT_TOKEN` is stored in GitHub Actions secrets. The service
account should have read access to exactly these two vaults:

- `webops-prod-shared`, which holds the `CLOUDFLARE` item with both
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
- `webops-prod-<project>`, which holds the Worker's app secrets.

The reusable workflow loads the two Cloudflare credentials from:

```text
op://webops-prod-shared/CLOUDFLARE/CLOUDFLARE_API_TOKEN
op://webops-prod-shared/CLOUDFLARE/CLOUDFLARE_ACCOUNT_ID
```

Do not include either credential in the caller's `secrets` input. The workflow
rejects those keys so they cannot override platform credentials.

Each app-secret line is `KEY=item/field`, resolved as
`op://<vault>/item/field`, or a full `op://...` reference. Treat full references
as security-sensitive: they can deliberately load any item readable by the
project service account.

## Caller shape

Prefer pinning the reusable workflow to a reviewed SHA. A floating `@main`
follows every central-workflow change automatically.

```yaml
name: Deploy Worker

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: cloudflare-deploy-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<sha>
    with:
      vault: webops-prod-my-worker
      secrets: |
        DATABASE_URL=my-worker/DATABASE_URL
        API_KEY=my-worker/API_KEY
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

The reusable workflow does not enforce concurrency. Keep a caller-side group to
prevent concurrent `secret bulk` and deploy operations from interleaving. The
full caller example lives in
[`examples/price-service/deploy.yml`](../examples/price-service/deploy.yml).

## Project requirements

This is a Bun workflow. The caller project needs a committed Bun lockfile and a
working `deploy` script. `bun install --frozen-lockfile` and `bun run deploy`
are the workflow's only project setup and deploy commands.

Wrangler resolves its configuration exactly as it would when the project runs
`bunx wrangler secret bulk` and `bun run deploy`. The reusable workflow does not
validate or select a Worker name, inspect the Wrangler configuration, pin a
Wrangler version, or reject named environments. Projects that use multiple
Workers or Wrangler environments must ensure their bulk command and deploy
script target the intended Worker.

## Secret lifecycle

Secret sync is additive for keys listed in the caller's `secrets` input:

| Event | Result |
| --- | --- |
| Declared key exists in 1Password | Uploaded or overwritten by `wrangler secret bulk` |
| Key is removed from `secrets` | Remains on the Worker until explicitly deleted |
| Dashboard-only key | Unchanged by this workflow |
| Deploy fails after bulk | New secrets may remain with previously deployed code |

The workflow does not list, reconcile, remove, or roll back Worker secrets.
To remove one, delete the binding in Cloudflare with `wrangler secret delete`
(or the dashboard) and remove it from the caller input.

## Greenfield Workers

`wrangler secret bulk` runs before `bun run deploy`. If Cloudflare rejects the
bulk operation because the Worker does not yet exist, the job stops; it does not
deploy and retry automatically. Bootstrap a new Worker with an empty `secrets`
input, then run it again with app secrets declared.

## Operational guidance

- Keep the Cloudflare API token scoped as narrowly as Cloudflare permits. It is
  shared by all service accounts that can read `webops-prod-shared`.
- Protect the caller's default branch: deploy-time code and the project
  configuration run after secrets are loaded.
- Disable or treat as break-glass other paths that deploy the same Worker, such
  as dashboard deploys, Workers Builds, local tokens, Terraform, or other CI.
- Do not print secret values or dump the job environment in application scripts.
- Pin actions and the reusable-workflow ref where repository policy requires it.

## Out of scope

- Cloudflare Pages.
- Automatic secret reconciliation, deletion, rollback, or greenfield retry.
- Central Worker-name allowlisting or Wrangler configuration validation.
- Central concurrency control.
