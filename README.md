# Yearn reusable deployment workflows

Reusable GitHub Actions workflows for deploying **Vercel** apps and **Cloudflare
Workers** with secrets resolved from 1Password.

Both workflows use a single caller-provided `OP_SERVICE_ACCOUNT_TOKEN` with
read-only access to exactly two vaults: `webops-prod-shared` and the project
vault named in `vault` (`webops-prod-<project>`). Each entry in `secrets` is
`KEY=item/field`, resolved as `op://<vault>/item/field` (or a full `op://...`
reference). Only `OP_SERVICE_ACCOUNT_TOKEN` lives in GitHub Actions secrets;
platform credentials and app secrets come from 1Password.

Actions, CLI tooling, and bun versions are pinned in the central workflows.
Prefer SHA-pinning the reusable workflow ref on callers when policy requires it.

Operating guides:

- Vercel: [Vercel Deployment Operating Guide](https://hackmd.io/@murderteeth/B1aFfRIXMx) · `specs/vercel.md`
- Cloudflare Workers: `specs/cloudflare.md`

## Vercel

`.github/workflows/vercel-deploy.yml` uses `amondnet/vercel-action` with
`vercel-build: true` so the runner runs `vercel pull → vercel build → deploy
--prebuilt`, inlines project secrets via `build-env`, creates GitHub Deployment
records, and publishes preview URLs on pull requests.

`webops-prod-shared` holds `VERCEL_TOKEN` and `VERCEL_ORG_ID`; the project vault
holds `VERCEL_PROJECT_ID` and the app secrets listed in `secrets`.

### Usage

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

Caller workflows must grant `pull-requests: write` (in addition to
`contents: read` and `deployments: write`). Reusable workflows cannot elevate
beyond the caller's token permissions, and preview URL comments on pull
requests require write access to pull requests.

### Inputs

| Name          | Required | Default   | Description                                                                 |
| ------------- | -------- | --------- | --------------------------------------------------------------------------- |
| `vault`       | yes      | —         | Project vault named `webops-prod-<project>`; source of the project-specific OP secrets. |
| `secrets`     | no       | `""`      | Multiline `KEY=item/field` entries resolved from the project vault (or a full `op://...` reference). |
| `environment` | no       | `preview` | Deploy target. Only `preview` and `production` are accepted.                |

### Secrets

| Name                       | Required | Description                                                                 |
| -------------------------- | -------- | --------------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | yes      | Caller-provided 1Password service account token scoped to `webops-prod-shared` and the project vault. |

### Outputs

| Name             | Description                                   |
| ---------------- | --------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel. |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

### Examples

- `examples/katana-apr-service/deploy.yml`
- `examples/yvusd-apr-service/deploy.yml`
- `examples/fapy-hook/deploy.yml`

## Cloudflare Workers

`.github/workflows/cloudflare-deploy.yml` deploys a Bun-based Cloudflare Worker:
it runs `bun install --frozen-lockfile` before loading secrets, loads
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from
`webops-prod-shared/CLOUDFLARE`, bulk-uploads declared Worker secrets, then
runs `bun run deploy`.

The caller supplies a Bun project with a committed lockfile and a working
`deploy` script. The workflow deliberately leaves Wrangler configuration,
named-environment choice, and dependency version policy to that project.

Do not list `CLOUDFLARE_API_TOKEN` or `CLOUDFLARE_ACCOUNT_ID` in `secrets` —
the workflow manages and rejects those keys. Secret sync is additive: only
declared keys are uploaded, and removed keys remain on the Worker until deleted
explicitly. The Worker must already exist before a deploy with non-empty
`secrets`; bootstrap it first with an empty `secrets` input (or create it
outside this workflow).

The reusable workflow does not set concurrency. Callers should serialize their
own deploys, as the canonical example does.

`vault` and `secrets` use the same `KEY=item/field` (or full `op://...`)
syntax as the Vercel workflow.

### Usage

Canonical caller: [`examples/price-service/deploy.yml`](examples/price-service/deploy.yml).
Operating guide: [`specs/cloudflare.md`](specs/cloudflare.md).

### Inputs

| Name      | Required | Default | Description                                                                 |
| --------- | -------- | ------- | --------------------------------------------------------------------------- |
| `vault`   | yes      | —       | Project vault named `webops-prod-<project>` (not `webops-prod-shared`); source of app secrets. |
| `secrets` | no       | `""`    | Multiline `KEY=item/field` entries (or full `op://...`) resolved from the project vault and bulk-uploaded as Worker secrets. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` are reserved. |

### Secrets

| Name                       | Required | Description                                                                 |
| -------------------------- | -------- | --------------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | yes      | Caller-provided 1Password service account token scoped to `webops-prod-shared` and the project vault. |

### Examples

- `examples/price-service/deploy.yml` — canonical Cloudflare Workers caller (price-service)
