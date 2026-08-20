# Vercel deploy

Reusable GitHub workflow for deploying Vercel projects with credentials
resolved from Doppler via OIDC. No static secrets live in GitHub.

The workflow authenticates to Doppler as a service-account identity using the
GitHub Actions OIDC token, fetches `VERCEL_TOKEN`, `VERCEL_ORG_ID` and
`VERCEL_PROJECT_ID` from the `deploy-configs` config of the given Doppler
project(s), and runs `vercel deploy` — the build happens remotely on Vercel
with the env vars synced there by Doppler Vercel integrations. App secrets
never pass through GitHub Actions.

`VERCEL_TOKEN` and `VERCEL_ORG_ID` come from the shared `webops-shared-prod`
project (`deploy-configs` config), defined in the workflow — one place to
rotate them across apps. The app project only holds its `VERCEL_PROJECT_ID`.

The deploy environment is derived from the triggering event, not passed by the
caller: pull requests deploy previews (Vercel preview, no `--prod`), anything
else deploys production (`--prod` on the Vercel CLI) and is accepted only for a
`push` to the caller repository's default branch; `workflow_dispatch`,
`schedule`, and pushes to any other branch are rejected before credentials are
loaded. The production identity's OIDC subject binding
(`ref:refs/heads/main`, see Doppler setup) is defense in depth on top of that
check. Fork pull requests are rejected (no OIDC token is issued for them).

The app project's `VERCEL_PROJECT_ID` is always read from `deploy-configs`
(one Vercel project, one ID). The workflow never fetches `prd` or `preview`.

Full operating guide: `specs/doppler-vercel.md`.

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

## Inputs

| Name          | Required | Default | Description                                                                 |
| ------------- | -------- | ------- | --------------------------------------------------------------------------- |
| `project`     | yes      | —       | Doppler project containing `VERCEL_PROJECT_ID` in `deploy-configs`.         |
| `identity-id` | yes      | —       | Doppler service-account identity for the event; loads shared + app `deploy-configs`. |

## Outputs

| Name             | Description                                    |
| ---------------- | ---------------------------------------------- |
| `deployment-url` | Preview or production URL returned by Vercel.  |

Consume it from a downstream job with
`${{ needs.deploy.outputs.deployment-url }}`.

## Doppler setup

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

### Residual risk

Preview and production runs both read the same `deploy-configs` configs.
Those configs hold only `VERCEL_PROJECT_ID` (app) and `VERCEL_TOKEN` +
`VERCEL_ORG_ID` (shared) today; anything later added there is exported to
the runner by the same action.

## Migration from Vercel-managed env vars

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

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
See `specs/doppler-vercel.md` for the full operating guide.

# PR checks

Reusable GitHub workflow that runs lint, format, typecheck and test on pull
requests. It handles no secrets and requests no OIDC token.

The workflow installs with bun and reads the caller repository's
`package.json` to decide which checks exist. A check whose script is absent
reports "skipped" instead of failing the job, so a repository that defines
only `lint` still gets a green run. Adding a `typecheck` script is what turns
the typecheck step on.

Because the job executes pull-request code, it runs with `contents: read`
only, checks out with `persist-credentials: false`, and pins both the actions
and the bun version. Never pass secrets to it.

There is no `build` check: the deploy workflow above already builds every pull
request on Vercel, and `next build` typechecks.

Full design: `specs/pr-checks.md`.

## Usage

```yaml
name: PR checks

on: pull_request

concurrency:
  group: pr-checks-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  checks:
    uses: yearn/yearn-gha/.github/workflows/pr-checks.yml@<approved-sha> # pin to the approved full commit SHA
```

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `bun-version` | no | `1.3.14` | Bun release installed by `oven-sh/setup-bun`. |

No outputs. No secrets.

## Checks

| Step | Script names | Behaviour when absent |
| ---- | ------------ | --------------------- |
| Lint | `lint` | skipped |
| Format | `format:check` | skipped |
| Typecheck | `typecheck`, `type-check` | skipped |
| Test | `test` | skipped |

There is no `format` fallback. A conventional `format` script rewrites files
and exits 0 whatever the input looked like, so the check could only fail on a
formatter crash.
