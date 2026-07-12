# Vercel deploy

Reusable GitHub workflow for deploying Vercel projects with secrets resolved
from 1Password by the calling workflow.

The workflow uses a single caller-provided `OP_SERVICE_ACCOUNT_TOKEN` scoped to
the project vault named in `vault` (`webops-prod-<project>`). That vault must
contain `VERCEL_TOKEN`, `VERCEL_ORG_ID`, the Vercel project ID, and the app
secrets listed in `secrets`.

The workflow pins its actions, Vercel CLI, and 1Password CLI versions. It uses
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
        VERCEL_PROJECT_ID=VERCEL_PROJECT_ID
        RPC_URL=RPC_URL
        WEBHOOK_SECRET=WEBHOOK_SECRET
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

Store `OP_SERVICE_ACCOUNT_TOKEN` as a repository secret on the caller. The
token must have access only to the project vault supplied in `vault`.

Caller workflows must grant `pull-requests: write` (in addition to
`contents: read` and `deployments: write`). Reusable workflows cannot elevate
beyond the caller's token permissions, and preview URL comments on pull
requests require write access to pull requests.

## Inputs

| Name                | Required | Default   | Description                                                                 |
| ------------------- | -------- | --------- | --------------------------------------------------------------------------- |
| `vault`             | yes      | —         | Project vault named `webops-prod-<project>`; source of all OP secrets.      |
| `secrets`           | no       | `""`      | Multiline `KEY=secret-name` entries resolved from the project vault.        |
| `environment`       | no       | `preview` | Deploy target. Only `preview` and `production` are accepted.                |

## Secrets

| Name                       | Required | Description                                                                 |
| -------------------------- | -------- | --------------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | yes      | Caller-provided 1Password service account token scoped to the project vault. |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
