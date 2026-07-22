# Vercel deploy

Reusable GitHub workflow for deploying Vercel projects with secrets resolved
from 1Password by the calling workflow.

The workflow uses a single caller-provided `OP_SERVICE_ACCOUNT_TOKEN` with
read-only access to exactly two vaults: `webops-prod-shared` and the project
vault named in `vault` (`webops-prod-<project>`). `webops-prod-shared` contains
a `vercel` item with `VERCEL_TOKEN` and `VERCEL_ORG_ID`; the project vault
contains a `VERCEL_PROJECT_ID` item and the app secrets listed in `secrets`.
Each entry in `secrets` is `KEY=item/field`, resolved as `op://<vault>/item/field`
(or pass a full `op://...` reference to point outside the project vault).
Entries keyed `VERCEL_TOKEN`, `VERCEL_ORG_ID`, or `VERCEL_PROJECT_ID` are
never pushed to Vercel; those credentials are managed by the workflow.

The workflow pins its actions, Vercel CLI, 1Password CLI, and bun versions. It
drives the Vercel CLI directly: 1Password is the source of truth, so before
building it replaces the Vercel project's env vars for the target environment
through the Vercel REST API. Every var scoped solely to that environment is
removed, then each `secrets` entry is re-added as a sensitive var;
`NEXT_PUBLIC_*` keys are added as plain vars instead so `vercel pull` can
supply them to the build. The sync refuses to run if an existing var also
targets another environment or a specific git branch, so it never destroys
config it doesn't own. It then runs
`vercel pull → vercel build` on a build job and `vercel deploy --prebuilt`
(`--prod` for production) on a separate deploy job. The deployment URL is
exposed as the `deployment-url` output. After a successful deploy the workflow
creates a GitHub Deployment record pointing at the URL, and on `pull_request`
events it also keeps a single marker-tagged PR comment updated with the latest
deployment URL.

Build and deploy run as separate jobs so untrusted app install/build scripts
cannot poison tools or helpers that later run with `VERCEL_TOKEN` or
`GITHUB_TOKEN`. The build job uploads only `.vercel/output` and
`.vercel/project.json` (no env files, no app scripts). The deploy job uses a
clean runner, reinstalls the Vercel CLI from the registry, re-checkouts helper
scripts from `yearn/yearn-gha`, and never executes binaries or scripts from the
build artifact. Within each job, secrets are still scoped to the steps that
need them (`export-env: false`, no token on the build step, checkouts use
`persist-credentials: false`). The build receives app env vars only through
`vercel pull`. Sensitive vars are write-only on Vercel: `vercel pull` yields a
`[SENSITIVE]` placeholder for them, so apps must read secrets at request time
(dynamic pages, route handlers). Only `NEXT_PUBLIC_*` values are real at build
time.

## Usage

```yaml
name: Deploy to Vercel

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  deployments: write
  pull-requests: write

jobs:
  deploy:
    # Fork PRs get no secrets and a read-only token; skip instead of failing.
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    uses: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@main
    with:
      vault: webops-prod-my-app
      environment: ${{ github.event_name == 'pull_request' && 'preview' || 'production' }}
      secrets: |
        RPC_URL=my-app/RPC_URL
        WEBHOOK_SECRET=my-app/WEBHOOK_SECRET
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

When pinning `uses` to a commit sha instead of `main`, pass the same sha as
`workflows-ref` so the helper scripts are checked out at the matching version.

Deploys are serialized per project and environment by a workflow-level
concurrency group (Vercel env vars are shared per project+environment, so
concurrent runs must not interleave across build and deploy). Callers don't
need their own `concurrency` block.

Store `OP_SERVICE_ACCOUNT_TOKEN` as a repository secret on the caller. The
token must have read-only access only to `webops-prod-shared` and the project
vault supplied in `vault`.

Caller workflows must grant `deployments: write` (GitHub Deployment record)
and, when triggering on `pull_request`, `pull-requests: write` (deployment URL
comment), in addition to `contents: read`. The prebuilt artifact upload/download
uses the runner's internal token, not `GITHUB_TOKEN`, so no `actions` permission
is needed. Reusable workflows cannot elevate beyond the caller's token
permissions. When triggering on `pull_request`, gate the job to same-repo PRs
(see example) — fork PRs get no secrets and a read-only token, so the run would
fail.

## Inputs

| Name                | Required | Default   | Description                                                                 |
| ------------------- | -------- | --------- | --------------------------------------------------------------------------- |
| `vault`             | yes      | —         | Project vault named `webops-prod-<project>`; source of the project-specific OP secrets. |
| `secrets`           | no       | `""`      | Multiline `KEY=item/field` entries resolved from the project vault (or a full `op://...` reference). |
| `environment`       | no       | `preview` | Deploy target. Only `preview` and `production` are accepted.                |
| `workflows-ref`     | no       | `""`      | Ref of `yearn/yearn-gha` to check out for helper scripts. Pass the same ref pinned in `uses`; defaults to `github.job_workflow_sha`, which GitHub leaves empty on some runs (falling back to `main`). |

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
