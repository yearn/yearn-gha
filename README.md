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
caller: pull requests deploy previews (Vercel preview, no `--prod`), anything
else deploys production (`--prod` on the Vercel CLI) and is accepted only for a
`push` to the caller repository's default branch; `workflow_dispatch`,
`schedule`, and pushes to any other branch are rejected before credentials are
loaded. The production identity's OIDC subject binding
(`ref:refs/heads/main`, see Infisical setup) is defense in depth on top of that
check. Fork pull requests are rejected (no OIDC token is issued for them).

By default the app project's `VERCEL_PROJECT_ID` is always read from
`prod:/deploy-config` (one Vercel project, one ID). Set `split-app-env: true`
to read the event-specific env instead (`dev` on pull requests, `prod`
otherwise) when preview and production deploy config must stay apart.

## Usage

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
      project-slug: my-app
      identity-id: ${{ github.event_name == 'pull_request' && vars.INFISICAL_PREVIEW_IDENTITY_ID || vars.INFISICAL_PRODUCTION_IDENTITY_ID }}
      # optional — default false; set true only if app keeps preview/prod deploy-config apart
      # split-app-env: true
```

Caller workflows must grant `id-token: write` (OIDC login to Infisical) and
`pull-requests: write` (preview URL comments), in addition to `contents: read`
and `deployments: write`. Reusable workflows cannot elevate beyond the
caller's token permissions. Configure `INFISICAL_PREVIEW_IDENTITY_ID` and
`INFISICAL_PRODUCTION_IDENTITY_ID` as Actions repository variables in each
caller. Use two identities; the `pull_request` vs
`ref:refs/heads/<default>` subject binding is what stops a PR from deploying
production.

## Inputs

| Name             | Required | Default | Description                                                                 |
| ---------------- | -------- | ------- | --------------------------------------------------------------------------- |
| `project-slug`   | yes      | —       | Infisical project slug containing `VERCEL_PROJECT_ID` under `/deploy-config`. |
| `identity-id`    | yes      | —       | Infisical machine identity for the event; loads shared + app `/deploy-config`. |
| `split-app-env`  | no       | `false` | When `true`, app fetch uses `dev` on `pull_request` and `prod` otherwise. When `false`, app fetch always uses `prod`. Shared fetch is always `prod`. |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

## Infisical setup

1. Create the shared `webops-prod-shared` project with `VERCEL_TOKEN` and
   `VERCEL_ORG_ID` under `/deploy-config` in the `prod` env, and a project per
   app with `VERCEL_PROJECT_ID` under `/deploy-config`.
   - **Default mode** (`split-app-env: false`): store the project ID once under
     the app project's `prod` env.
   - **Split mode** (`split-app-env: true`): store it under both `dev` (previews)
     and `prod` (production).
   Keep ONLY those creds under `/deploy-config` — the workflow exports every
   secret at that path onto the runner.
2. App secrets live at the project root (`/`) and reach Vercel via a Secret
   Sync per env (`dev` → Vercel Preview, `prod` → Vercel Production), with
   sensitive on. Note: syncing `/` does not include subfolders, which is what
   keeps `/deploy-config` out of the app env.
3. Create separate preview and production machine identities with OIDC Auth.
   Both use discovery/issuer URL
   `https://token.actions.githubusercontent.com` and audience
   `https://github.com/<org>`.
   - Preview identity subject: `repo:<org>/<repo>:pull_request`. Add claims
     `job_workflow_ref: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha>`
     and `event_name: pull_request`.
   - Production identity subject:
     `repo:<org>/<repo>:ref:refs/heads/main` (replace `main` if the default
     branch differs). Add claims
     `job_workflow_ref: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha>`,
     `event_name: push`, and `ref: refs/heads/<default-branch>`.

   Grant each identity read access only to the paths it will fetch:

   | Mode | Identity | Shared project | App project |
   | ---- | -------- | -------------- | ----------- |
   | Default | Preview (`pull_request`) | `prod:/deploy-config` | `prod:/deploy-config` |
   | Default | Production (`push`) | `prod:/deploy-config` | `prod:/deploy-config` |
   | Split | Preview (`pull_request`) | `prod:/deploy-config` | `dev:/deploy-config` |
   | Split | Production (`push`) | `prod:/deploy-config` | `prod:/deploy-config` |

   In split mode, the preview identity must not have access to the app
   project's production path.
   - Set a short access-token TTL and a bounded max uses on both identities'
     auth method — deploys are short-lived, so tokens do not need to outlive them.
4. Pass the event-appropriate identity ID as `identity-id` in the caller, as
   shown above. The same identity authenticates both the shared
   (`webops-prod-shared`) and app project fetches.

### Residual risk (default mode)

Preview runs, triggerable by any same-repo PR, read the app project's
`prod:/deploy-config`. That path holds only `VERCEL_PROJECT_ID` today; anything
later added there is exported to the runner by the same action. Use
`split-app-env: true` (and the split grants above) when the app cannot accept
that.

## Migration from Vercel-managed env vars

1. Set up the Vercel integration in Infisical.
2. Create a Secret Sync per env with **auto-sync and deletion disabled**:
   - `dev:/` → Vercel Preview
   - `prod:/` → Vercel Production
   Root folder only (`/`); subfolders (including `/deploy-config`) are not
   synced.
3. Run the initial import with **Import Secrets (Prioritize Vercel)** so live
   Vercel values win. Sensitive Vercel values often import empty — re-enter
   them in Infisical after the import.
4. Diff Infisical against Vercel (keys and values) before enabling auto-sync.
5. Enable auto-sync one environment at a time after verifying the target, key
   set, and values.
6. Put deploy credentials (`VERCEL_TOKEN`, `VERCEL_ORG_ID`,
   `VERCEL_PROJECT_ID`) under `/deploy-config` as described in Infisical setup —
   not in the synced root.

Do the same steps for the preview environment if needed.

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
