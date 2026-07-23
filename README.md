# Vercel deploy

Reusable GitHub workflow for deploying Vercel projects with credentials
resolved from Infisical via OIDC. No static secrets live in GitHub.

The workflow authenticates to Infisical as a machine identity using the GitHub
Actions OIDC token, fetches `VERCEL_TOKEN`, `VERCEL_ORG_ID` and
`VERCEL_PROJECT_ID` from the `/deploy-config` folder of the given Infisical
project(s), and runs `vercel deploy` — the build happens remotely on Vercel
with the env vars synced there by Infisical Secret Syncs. App secrets never
pass through GitHub Actions.

With `shared-project-slug` set, `VERCEL_TOKEN` and `VERCEL_ORG_ID` come from
that shared project (`prod` env, `/deploy-config`) — one place to rotate them
across apps — and the app project only holds its `VERCEL_PROJECT_ID`. Without
it, the app project's `/deploy-config` must contain all three.

`environment` maps to the Infisical env slug: `preview` → `dev`,
`production` → `prod`. Production deploys pass `--prod` to the Vercel CLI.
Fork pull requests are rejected (no OIDC token is issued for them).

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
  id-token: write
  pull-requests: write

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@main
    with:
      shared-project-slug: webops-prod-shared
      project-slug: my-app
      identity-id: 00000000-0000-0000-0000-000000000000
      environment: ${{ github.event_name == 'pull_request' && 'preview' || 'production' }}
```

Caller workflows must grant `id-token: write` (OIDC login to Infisical) and
`pull-requests: write` (preview URL comments), in addition to `contents: read`
and `deployments: write`. Reusable workflows cannot elevate beyond the
caller's token permissions.

## Inputs

| Name                  | Required | Default   | Description                                                                     |
| --------------------- | -------- | --------- | ------------------------------------------------------------------------------- |
| `project-slug`        | yes      | —         | Infisical project slug containing `VERCEL_PROJECT_ID` under `/deploy-config` (plus `VERCEL_TOKEN` and `VERCEL_ORG_ID` when `shared-project-slug` is unset). |
| `shared-project-slug` | no       | `''`      | Infisical project slug containing `VERCEL_TOKEN` and `VERCEL_ORG_ID` under `/deploy-config` (`prod` env), shared across apps. |
| `identity-id`         | yes      | —         | Infisical machine identity ID (safe to commit; auth comes from OIDC claims).    |
| `environment`         | no       | `preview` | Deploy target. Only `preview` and `production` are accepted.                    |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

## Infisical setup

1. Create a shared project with `VERCEL_TOKEN` and `VERCEL_ORG_ID` under
   `/deploy-config` in the `prod` env, and a project per app with
   `VERCEL_PROJECT_ID` under `/deploy-config` in each env (`dev` for previews,
   `prod` for production). Keep ONLY those creds there — the workflow exports
   every secret at that path onto the runner. (Without a shared project, put
   all three in the app project's `/deploy-config` and omit
   `shared-project-slug`.)
2. App secrets live at the project root (`/`) and reach Vercel via a Secret
   Sync per env (`dev` → Vercel Preview, `prod` → Vercel Production), with
   sensitive on. Note: syncing `/` does not include subfolders, which is what
   keeps `/deploy-config` out of the app env.
3. Create a machine identity with OIDC Auth:
   - Discovery/issuer URL: `https://token.actions.githubusercontent.com`
   - Audience: `https://github.com/<org>`
   - Subject: `repo:<org>/<repo>:pull_request` (previews) or
     `repo:<org>/<repo>:ref:refs/heads/main` (production)
   - Grant it read access to `/deploy-config` only, on both the shared and
     the app project.
4. Pass the identity's ID as `identity-id` in the caller.

## Migration from Vercel-managed env vars

Set the first sync to import from destination (Infisical wins on conflicts) —
never overwrite on first sync — and diff Vercel vs Infisical before trusting
auto-sync. Sensitive Vercel values are not readable via API; re-enter them in
Infisical manually.

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
