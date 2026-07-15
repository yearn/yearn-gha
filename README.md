# Yearn reusable deployment workflows

Reusable GitHub workflow for deploying Vercel projects with secrets resolved
from 1Password by the calling workflow.

The workflow uses a single caller-provided `OP_SERVICE_ACCOUNT_TOKEN` with
read-only access to exactly two vaults: `webops-prod-shared` and the project
vault named in `vault` (`webops-prod-<project>`). `webops-prod-shared` contains
`VERCEL_TOKEN` and `VERCEL_ORG_ID`; the project vault contains a
`VERCEL_PROJECT_ID` item and the app secrets listed in `secrets`. Each entry
in `secrets` is `KEY=item/field`, resolved as `op://<vault>/item/field`
(or pass a full `op://...` reference to point outside the project vault).

The workflow pins its actions, Vercel CLI, 1Password CLI, and bun versions. It uses
`amondnet/vercel-action` with `vercel-build: true` so the runner runs
`vercel pull → vercel build → deploy --prebuilt`, inlines project secrets via
`build-env`, creates GitHub Deployment records, and publishes preview URLs on
pull requests.

## Usage

```yaml
name: Deploy to Vercel

on:
  push:
    branches: [main]

permissions:
  contents: read
  deployments: write
  pull-requests: write

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@main
    with:
      vault: webops-prod-my-app
      environment: production
      secrets: |
        RPC_URL=my-app/RPC_URL
        WEBHOOK_SECRET=my-app/WEBHOOK_SECRET
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

Store `OP_SERVICE_ACCOUNT_TOKEN` as a repository secret on the caller. The
token must have read-only access only to `webops-prod-shared` and the project
vault supplied in `vault`.

Caller workflows must grant `pull-requests: write` (in addition to
`contents: read` and `deployments: write`). Reusable workflows cannot elevate
beyond the caller's token permissions, and preview URL comments on pull
requests require write access to pull requests.

## Inputs

| Name                | Required | Default   | Description                                                                 |
| ------------------- | -------- | --------- | --------------------------------------------------------------------------- |
| `vault`             | yes      | —         | Project vault named `webops-prod-<project>`; source of the project-specific OP secrets. |
| `secrets`           | no       | `""`      | Multiline `KEY=item/field` entries resolved from the project vault (or a full `op://...` reference). |
| `environment`       | no       | `preview` | Deploy target. Only `preview` and `production` are accepted.                |

## Secrets

| Name                       | Required | Description                                                                 |
| -------------------------- | -------- | --------------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | yes      | Caller-provided 1Password service account token scoped to `webops-prod-shared` and the project vault. |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.

## Cloudflare Workers

`.github/workflows/cloudflare-deploy.yml` deploys a Bun-based Cloudflare Worker.
Callers must ship a committed `bun.lock`/`bun.lockb`, a `deploy` script, and
`wrangler` as a direct dependency. The workflow installs with
`bun install --frozen-lockfile` (before any secrets load), resolves
`CLOUDFLARE_API_TOKEN` from `webops-prod-shared/CLOUDFLARE` and
`CLOUDFLARE_ACCOUNT_ID` from the project vault, uploads declared Worker secrets
with `wrangler secret bulk`, then runs `bun run deploy`. Do not list either
Cloudflare credential in `secrets`. Named Wrangler environments (`--env`) are
not supported.

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
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@main
    with:
      vault: webops-prod-my-worker
      secrets: |
        DATABASE_URL=my-worker/DATABASE_URL
        API_KEY=my-worker/API_KEY
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

`vault` and `secrets` use the same `KEY=item/field` (or full `op://...`)
syntax as the Vercel workflow. The caller's 1Password token needs read access
to both `webops-prod-shared` and the selected project vault. Callers must set a
concurrency group so parallel deploys do not interleave secret bulk and deploy.
