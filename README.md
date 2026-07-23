# Vercel deploy

Reusable GitHub workflow for deploying Vercel projects with credentials
resolved from Infisical via OIDC. No static secrets live in GitHub.

The workflow authenticates to Infisical as a machine identity using the GitHub
Actions OIDC token, fetches `VERCEL_TOKEN`, `VERCEL_ORG_ID` and
`VERCEL_PROJECT_ID` from the `/deploy-config` folder of the given Infisical
project(s), and runs `vercel deploy` — the build happens remotely on Vercel
with the env vars synced there by Infisical Secret Syncs. App secrets never
pass through GitHub Actions.

`VERCEL_TOKEN` and `VERCEL_ORG_ID` come from the shared `webops-prod-shared`
project (`prod` env, `/deploy-config`), defined in the workflow — one place to
rotate them across apps. The app project only holds its `VERCEL_PROJECT_ID`.

The deploy environment is derived from the triggering event, not passed by the
caller: pull requests deploy previews (Infisical env `preview-env-slug`,
default `dev`), anything else deploys production (Infisical env `env-slug`,
default `prod`, `--prod` on the Vercel CLI) and is accepted only for a `push`
to the caller repository's default branch. Fork pull requests are rejected (no
OIDC token is issued for them).

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
      project-slug: my-app
      identity-id: ${{ github.event_name == 'pull_request' && vars.INFISICAL_PREVIEW_IDENTITY_ID || vars.INFISICAL_PRODUCTION_IDENTITY_ID }}
```

Caller workflows must grant `id-token: write` (OIDC login to Infisical) and
`pull-requests: write` (preview URL comments), in addition to `contents: read`
and `deployments: write`. Reusable workflows cannot elevate beyond the
caller's token permissions. Configure `INFISICAL_PREVIEW_IDENTITY_ID` and
`INFISICAL_PRODUCTION_IDENTITY_ID` as Actions repository variables in each
caller (or replace the variable references with the corresponding identity
IDs, which are safe to commit).

## Inputs

| Name               | Required | Default | Description                                                                   |
| ------------------ | -------- | ------- | ----------------------------------------------------------------------------- |
| `project-slug`     | yes      | —       | Infisical project slug containing `VERCEL_PROJECT_ID` under `/deploy-config`. |
| `identity-id`      | yes      | —       | Infisical machine identity ID for the event-derived deploy environment.       |
| `preview-env-slug` | no       | `dev`   | Infisical environment slug used for pull request preview deploys.             |
| `env-slug`         | no       | `prod`  | Infisical environment slug used for production deploys.                       |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

## Infisical setup

1. Create the shared `webops-prod-shared` project with `VERCEL_TOKEN` and
   `VERCEL_ORG_ID` under `/deploy-config` in the `prod` env, and a project per
   app with `VERCEL_PROJECT_ID` under `/deploy-config` in each env (`dev` for
   previews, `prod` for production). Keep ONLY those creds there — the
   workflow exports every secret at that path onto the runner.
2. App secrets live at the project root (`/`) and reach Vercel via a Secret
   Sync per env (`dev` → Vercel Preview, `prod` → Vercel Production), with
   sensitive on. Note: syncing `/` does not include subfolders, which is what
   keeps `/deploy-config` out of the app env.
3. Create separate preview and production machine identities with OIDC Auth.
   Both use discovery/issuer URL
   `https://token.actions.githubusercontent.com` and audience
   `https://github.com/<org>`.
   - Preview identity subject: `repo:<org>/<repo>:pull_request`. Grant it read
     access to `/deploy-config` only in the shared project's `prod` env and
     the app project's `dev` env.
   - Production identity subject:
     `repo:<org>/<repo>:ref:refs/heads/main` (replace `main` if the default
     branch differs). Grant it read access to `/deploy-config` only in the
     shared project's `prod` env and the app project's `prod` env.
4. Pass the event-appropriate identity ID as `identity-id` in the caller, as
   shown above.

## Migration from Vercel-managed env vars

Set the first sync to import from destination (Infisical wins on conflicts) —
never overwrite on first sync — and diff Vercel vs Infisical before trusting
auto-sync. Sensitive Vercel values are not readable via API; re-enter them in
Infisical manually.

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
