# Deploy workflows

Reusable GitHub workflows for deploying to Vercel and Cloudflare Workers with
credentials resolved from Doppler via OIDC. No static secrets live in GitHub.

Both workflows share the same skeleton: authenticate to Doppler as a
service-account identity using the GitHub Actions OIDC token, fetch only the
deploy credentials, and deploy. The deploy environment is derived from the
triggering event, never passed by the caller. Vercel deploys previews for
pull requests and production for a `push` to the caller repository's default
branch; Cloudflare Workers deploys production only. Unsupported events
(`workflow_dispatch`, `schedule`, non-default-branch pushes, fork pull
requests) are rejected before credentials are loaded.

| Workflow | Guide |
| -------- | ----- |
| `.github/workflows/vercel-deploy.yml` | `specs/doppler-vercel.md` |
| `.github/workflows/cloudflare-deploy.yml` | `specs/doppler-cloudflare.md` |

## Vercel deploy

The workflow fetches `VERCEL_TOKEN`, `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID`
from the `deploy-configs` config of the given Doppler project(s), and runs
`vercel deploy` — the build happens remotely on Vercel with the env vars
synced there by Doppler Vercel integrations. App secrets never pass through
GitHub Actions.

`VERCEL_TOKEN` and `VERCEL_ORG_ID` come from the shared `webops-shared-prod`
project (`deploy-configs` config), defined in the workflow — one place to
rotate them across apps. The app project only holds its `VERCEL_PROJECT_ID`,
always read from `deploy-configs` (one Vercel project, one ID). The workflow
never fetches `prd` or `preview`.

Pull requests deploy Vercel previews (no `--prod`); a default-branch push
deploys production (`--prod`). The production identity's OIDC subject binding
(`ref:refs/heads/main`, see Doppler setup) is defense in depth on top of the
workflow's own event checks.

### Usage

```yaml
name: Deploy to Vercel

on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: vercel-deploy-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  deployments: write
  id-token: write
  pull-requests: write

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha> # pin to the approved full commit SHA
    with:
      project: my-app
      identity-id: ${{ github.event_name == 'pull_request' && vars.DOPPLER_PREVIEW_IDENTITY_ID || vars.DOPPLER_PRODUCTION_IDENTITY_ID }}
```

Caller workflows must grant `id-token: write` (OIDC login to Doppler) and
`pull-requests: write` (preview URL comments), in addition to `contents: read`
and `deployments: write`. Reusable workflows cannot elevate beyond the
caller's token permissions. Configure `DOPPLER_PREVIEW_IDENTITY_ID` and
`DOPPLER_PRODUCTION_IDENTITY_ID` as Actions repository variables in each
caller. Use two identities; the `pull_request` vs
`ref:refs/heads/<default>` subject binding is what stops a PR from deploying
production.

### Inputs

| Name          | Required | Default | Description                                                                 |
| ------------- | -------- | ------- | --------------------------------------------------------------------------- |
| `project`     | yes      | —       | Doppler project containing `VERCEL_PROJECT_ID` in `deploy-configs`.         |
| `identity-id` | yes      | —       | Doppler service-account identity for the event; loads shared + app `deploy-configs`. |

### Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

### Doppler setup

1. Create the shared `webops-shared-prod` project with `VERCEL_TOKEN` and
   `VERCEL_ORG_ID` in the `deploy-configs` config, and a project per app with
   `VERCEL_PROJECT_ID` in `deploy-configs`.
   Keep ONLY those creds in `deploy-configs` — the workflow exports every
   secret in that config onto the runner.
   Set `VERCEL_TOKEN` visibility to Masked. The fetch action registers
   GitHub log redaction only for values that are not Unmasked; an Unmasked
   token shows in plaintext if it reaches a log.
2. App secrets live in `prd` and `preview` and reach Vercel via one
   integration per env (`preview` → Vercel Preview, `prd` → Vercel
   Production), with Sensitive on. Do not attach a Vercel integration to
   `deploy-configs`.
3. Create separate preview and production service-account identities with
   OIDC. Both use discovery/issuer URL
   `https://token.actions.githubusercontent.com`. Audience must match the
   token the fetch action requests (no custom audience; typically
   `https://github.com/<org>` — confirm against a real token).
   - Preview identity subject: `repo:<org>/<repo>:pull_request`. Add claims
     `job_workflow_ref: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha>`
     and `event_name: pull_request`.
   - Production identity subject:
     `repo:<org>/<repo>:ref:refs/heads/main` (replace `main` if the default
     branch differs). Add claims
     `job_workflow_ref: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha>`,
     `event_name: push`, and `ref: refs/heads/<default-branch>`.

   Grant each identity read access only to the configs it will fetch:

   | Identity | Shared project | App project |
   | -------- | -------------- | ----------- |
   | Preview (`pull_request`) | `webops-shared-prod` / `deploy-configs` | `<app>` / `deploy-configs` |
   | Production (`push`) | `webops-shared-prod` / `deploy-configs` | `<app>` / `deploy-configs` |

   Do not grant the deploy identities access to `prd` or `preview`.
4. Pass the event-appropriate identity ID as `identity-id` in the caller, as
   shown above. The same identity authenticates both the shared
   (`webops-shared-prod`) and app project fetches.

#### Residual risk

Preview and production runs both read the same `deploy-configs` configs.
Those configs hold only `VERCEL_PROJECT_ID` (app) and `VERCEL_TOKEN` +
`VERCEL_ORG_ID` (shared) today; anything later added there is exported to
the runner by the same action.

### Migration from Vercel-managed env vars

1. Set up the Vercel integration in Doppler.
2. Create one integration per env:
   - `preview` → Vercel Preview
   - `prd` → Vercel Production
   Do not attach `deploy-configs` to any Vercel environment.
3. Import or re-enter live Vercel values. Sensitive Vercel values often
   import empty — re-enter them in Doppler after the import.
4. Diff Doppler against Vercel (keys and values) before treating the sync as
   authoritative.
5. Enable one integration at a time after verifying the target, key set, and
   values.
6. Put deploy credentials (`VERCEL_TOKEN`, `VERCEL_ORG_ID`,
   `VERCEL_PROJECT_ID`) in `deploy-configs` as described in Doppler setup —
   not in `prd` or `preview`.

Do the same steps for the preview environment if needed.

## Cloudflare Workers deploy

The workflow installs dependencies with bun (pinned to `1.3.14`,
`--frozen-lockfile`), fetches `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` as step outputs from the `cloudflare-deploy-configs`
config of the shared `webops-shared-prod` project, and runs
`wrangler deploy`. No `wranglerVersion` is passed, so wrangler-action uses
the wrangler the app repository installed — pin wrangler in the app's
devDependencies and lockfile. There is no per-app Doppler deploy project:
the worker's identity is its name in the app repository's `wrangler.toml`,
so the workflow takes only `identity-id`.

Callers must ship a bun lockfile and a wrangler devDependency; otherwise
`bun install --frozen-lockfile` fails before Doppler is reached. The
workflow is deploy-only — run smoke tests in a `needs: deploy` job in the
caller (see `examples/rpc-read-proxy/deploy.yml`).

Production only — the workers fleet has no preview environment. The only
supported trigger is a push to the caller repository's default branch;
`pull_request`, `workflow_dispatch`, `schedule`, and non-default-branch
pushes are rejected before Doppler authentication.

Unlike Vercel there is no remote build: wrangler bundles the worker on the
runner. Worker runtime secrets never pass through this workflow — they are
synced to Cloudflare out of band with Doppler's DIY Workers flow
(`doppler secrets --json | jq -c 'with_entries(.value = .value.computed)' |
wrangler secret bulk`). See `specs/doppler-cloudflare.md` for the full risk
discussion.

The Cloudflare config is deliberately separate from the Vercel
`deploy-configs` so neither platform's deploy exports the other's
credentials onto its runner.

### Usage

```yaml
name: Deploy to Cloudflare Workers

on:
  push:
    branches: [main]

concurrency:
  group: cloudflare-deploy-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha> # pin to the approved full commit SHA
    with:
      identity-id: ${{ vars.DOPPLER_PRODUCTION_IDENTITY_ID }}
```

Callers grant only `contents: read` and `id-token: write` — wrangler-action
posts no PR comments and creates no GitHub deployments. Configure
`DOPPLER_PRODUCTION_IDENTITY_ID` as an Actions repository variable in each
caller (a repository deploys to one platform, so the name does not collide
with Vercel callers).

### Inputs

| Name          | Required | Default | Description                                                          |
| ------------- | -------- | ------- | -------------------------------------------------------------------- |
| `identity-id` | yes      | —       | Production Doppler service-account identity; loads the shared `cloudflare-deploy-configs`. |

### Outputs

| Name             | Description                                              |
| ---------------- | -------------------------------------------------------- |
| `deployment-url` | Production URL from wrangler. Empty for a worker with no `workers.dev` subdomain or route; the first target only for a multi-route worker. |

### Doppler setup

1. In `webops-shared-prod`, create the `cloudflare-deploy-configs` config
   with `CLOUDFLARE_API_TOKEN` (visibility Masked; Cloudflare permissions:
   Workers Scripts Edit) and `CLOUDFLARE_ACCOUNT_ID`. Keep ONLY those two
   values there — every value in the config is fetched onto the runner as a
   step output.
2. Keep each worker's runtime secrets in its own Doppler project and sync
   them with the DIY `wrangler secret bulk` flow, outside this workflow.
   The deploy identities get no access to those configs.
3. Create one production identity per repository, as in the Vercel
   production setup: subject `repo:<org>/<repo>:ref:refs/heads/<default>`,
   claims `event_name: push`, `ref: refs/heads/<default>`, and
   `job_workflow_ref: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha>`,
   with read access only to `webops-shared-prod` /
   `cloudflare-deploy-configs`.
4. Pass the identity ID as `identity-id` in the caller.

See `examples/` for the current Katana APR, yvUSD APR, fapy-hook (Vercel)
and rpc-read-proxy (Cloudflare Workers) shapes.
See `specs/doppler-vercel.md` and `specs/doppler-cloudflare.md` for the full
operating guides.
