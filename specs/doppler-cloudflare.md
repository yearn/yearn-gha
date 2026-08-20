# Cloudflare Workers Deployment Operating Guide (Doppler)

- **Date:** 2026-08-18
- **Status:** Implemented in `yearn/yearn-gha`. Complete the per-app migration runbook before cutting a worker over.
- **Context:** Companion to `specs/doppler-vercel.md`. Same threat model (TanStack npm supply-chain compromise of May 2026), same Doppler OIDC pattern, applied to Cloudflare Workers. It matches the reusable workflow in `.github/workflows/cloudflare-deploy.yml`.

## Decision

GitHub Actions builds the worker on the runner and deploys it with wrangler. GitHub Actions authenticates to Doppler with OIDC, so GitHub stores no long-lived Doppler credential. The runner receives only the shared Cloudflare deploy credentials; worker runtime secrets reach Cloudflare out of band (see "Application secrets" below), never through this workflow.

**Production only — there are no previews.** The workers fleet has no preview environment, so the only supported trigger is a push to the caller repository's default branch. Every other event (`pull_request`, `pull_request_target`, `workflow_dispatch`, `schedule`, non-default-branch pushes) is rejected before Doppler authentication. This is the main event-model difference from the Vercel design.

The fleet uses one **shared account-scoped Cloudflare API token**. Store `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` once in `webops-shared-prod` / `cloudflare-deploy-configs`. The reusable workflow hardcodes both slugs (`.github/workflows/cloudflare-deploy.yml:20-21`) — callers do not pass them. A leaked token can reach every worker in the account.

**The Cloudflare config is separate from the Vercel `deploy-configs`.** `dopplerhq/secrets-fetch-action` with `inject-env-vars: true` exports every value in the fetched config. One combined config would put the Vercel token on every Cloudflare runner and the Cloudflare token on every Vercel runner. A separate config keeps each platform's blast radius to its own token.

There is no per-app Doppler deploy project. Vercel needs a per-app `VERCEL_PROJECT_ID`; a worker's identity is its name in the app repository's `wrangler.toml`. The workflow therefore takes only `identity-id` — no `project` input, and no second Doppler fetch.

The guide distinguishes three kinds of data:

- **Deployment secret:** `CLOUDFLARE_API_TOKEN`. Long-lived Cloudflare credential even though Doppler authentication is short-lived.
- **Deployment identifier:** `CLOUDFLARE_ACCOUNT_ID`. Selects the account; configuration, not authentication.
- **Application secrets:** API tokens, RPC credentials, signing keys and similar values the worker reads at runtime.

## Application secrets: out of band, out of this workflow

Doppler has a managed sync integration for Cloudflare **Pages**, but not for Cloudflare **Workers** — Workers is documented under Doppler's DIY syncs. The supported path is:

```shell
doppler secrets --json | jq -c 'with_entries(.value = .value.computed)' | wrangler secret bulk
```

run by an operator (or a separately reviewed sync job) with a config-scoped Doppler token, per app, whenever secrets change.

> The deploy workflow never fetches application secrets. Keeping the sync out of the deploy path is what preserves the invariant that app secrets do not touch the deploy runner.

Rejected alternative: syncing secrets inside the deploy workflow. It would require granting the deploy identity read access to the app secret config and exporting every app secret onto the runner on every deploy — exactly what the Vercel design exists to avoid.

## What this design protects—and what it does not

Provided controls (shared with the Vercel design):

- No static Doppler credential in GitHub; OIDC tokens are short-lived.
- Application secrets never pass through the deploy runner.
- The shared Cloudflare token is stored once, in one Doppler config, isolated from the Vercel credentials.
- One trusted reusable workflow implements event checks, action pins, the bun pin, and validation.
- Callers pin the reusable workflow to a full commit SHA; Doppler identities bind `job_workflow_ref` to that SHA.
- All events except a push to the default branch are rejected before Doppler authentication. Pull requests never obtain credentials, so fork-PR and pwn-request paths never reach Doppler.

Not eliminated:

- `CLOUDFLARE_API_TOKEN` is still a long-lived credential exposed to wrangler on the runner. Compromise is account-wide.
- **The build runs on the runner.** Unlike Vercel remote builds, wrangler bundles the worker on the runner, so third-party dependency code executes during the deploy. The workflow narrows the exposure: the app's own `bun install` runs before the Doppler fetch, and the credentials are read as step outputs (`inject-env-vars: false`) rather than injected into the job environment, so that install's scripts never see them; after the fetch, only the validate step (explicit env mapping) and the wrangler-action inputs receive them. The workflow also passes no `wranglerVersion`, so wrangler-action runs no install of its own in the step that holds the token. Residual risk: dependency code that wrangler-action bundles still runs in that step; a compromised dependency can exfiltrate the token there. Mitigation is dependency hygiene (lockfiles, review of lockfile diffs), not this workflow.
- **Step ordering is not an authorization boundary.** `id-token: write` is job-scoped, so any code that runs earlier in the job can mint the same OIDC token and fetch from Doppler itself. Running the install first keeps the fetched values out of the install step's environment; it does not keep dependency code away from the credential.
- OIDC policy is an authorization boundary only when all relevant claims are checked; identity IDs are public metadata.

## Target architecture

- A small caller workflow in each worker repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- The only supported trigger is a push to the caller repository's default branch, which runs `wrangler deploy`. Everything else is rejected before Doppler authentication.
- The workflow installs dependencies with `bun install --frozen-lockfile` (the fleet standardizes on bun, pinned to `1.3.14` in the workflow), then fetches `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from `webops-shared-prod` / `cloudflare-deploy-configs` as step outputs, validates them, and runs `wrangler deploy` via `cloudflare/wrangler-action`. No `wranglerVersion` is passed: wrangler-action uses the wrangler the app repository already installed, so the wrangler pin is the app's lockfile.
- **Precondition: the caller repository ships a bun lockfile** (`bun.lock` or `bun.lockb`) and a wrangler devDependency. `bun install --frozen-lockfile` fails otherwise, before Doppler is reached. `yearn/yearn-rpc-read-proxy` meets this today; `yearn/dns-bot` ships `package-lock.json` and must migrate to bun before it can call this workflow.
- Post-deploy verification (smoke tests) stays in the caller as a `needs: deploy` job — the reusable workflow is deploy-only.
- Output: `deployment-url` — the production URL parsed by the action. It is empty for a worker with no `workers.dev` subdomain or route, and is only the first target for a multi-route worker.

### Caller shape

```yaml
name: Deploy to Cloudflare Workers

on:
  push:
    branches: [main] # or master — match the repository default branch

concurrency:
  group: cloudflare-deploy-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha> # full commit SHA only
    with:
      identity-id: ${{ vars.DOPPLER_PRODUCTION_IDENTITY_ID }}
```

Repository variable: `DOPPLER_PRODUCTION_IDENTITY_ID`. Identity IDs are not secrets.

### Workflow inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `identity-id` | yes | — | Production Doppler service-account identity; used for the shared `cloudflare-deploy-configs` fetch. |

Output: `deployment-url` (production URL).

### Rejected alternatives

- **PR preview deploys (`wrangler versions upload`).** The fleet has no preview environment. Worker secrets are also per-worker, not per-version, so a PR preview version would run against production secrets — same-repo PR code could read them at runtime. If previews are ever wanted, add them as a separately reviewed change that confronts that risk directly.
- **Cloudflare Pages.** The fleet's Cloudflare footprint is Workers (`yearn/yearn-rpc-read-proxy`, and `yearn/dns-bot` once it moves to bun); Cloudflare's own direction folds Pages into Workers (static assets on Workers). Doppler's managed Pages sync does not apply to Workers projects.
- **Per-app Cloudflare API tokens.** Cloudflare tokens scope to account/zone, not to a single worker, so per-app tokens buy little isolation at a real management cost. Revisit if Cloudflare ships per-worker token scoping.
- **Per-app Doppler deploy project.** Nothing app-specific to store — the worker name lives in `wrangler.toml`. An empty per-app fetch is pure surface.
- **`workflow_dispatch` manual deploys.** Same rationale as Vercel: broadens deployment authority and bypasses the event gate. Add a separately reviewed, approval-gated manual path only if an operational need emerges.
- **Secrets sync inside the deploy workflow.** See "Application secrets" above.

## Doppler configuration

Service Account Identities require a Doppler Team or Enterprise workplace.

### Shared deployment project

In the existing `webops-shared-prod` Doppler project, add environment / config `cloudflare-deploy-configs`:

- `CLOUDFLARE_API_TOKEN`: shared account-scoped token. Cloudflare permissions: Workers Scripts Edit (plus Workers Routes Edit if workers manage routes). Set Doppler visibility to **Masked** — the fetch action registers GitHub log redaction only for values that are not Unmasked.
- `CLOUDFLARE_ACCOUNT_ID`

Keep only those two values in the config: every value in it is fetched onto the runner as a step output. Do not add the Vercel credentials here, and do not add the Cloudflare credentials to the Vercel `deploy-configs`.

### Application project

One Doppler project per worker holding its runtime secrets (e.g. `prd`). These configs are synced to Cloudflare by the DIY `wrangler secret bulk` flow, run outside this workflow. The deploy identity gets **no** access to them.

### Service accounts, identities, and OIDC

Create one production Doppler service-account identity per worker repository. Grant the underlying service account read-only access to exactly one config: `webops-shared-prod` / `cloudflare-deploy-configs`.

The identity uses:

- Provider: GitHub (`https://token.actions.githubusercontent.com`)
- Audience matching the action's token (verify against a real token; usually `https://github.com/<org>`)
- Subject: `repo:<org>/<repo>:ref:refs/heads/<default-branch>` (or the immutable-format equivalent)
- Exact additional claims: `event_name=push`, `ref=refs/heads/<default-branch>`, and `job_workflow_ref=yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha>`
- No wildcards on claims.

The `job_workflow_ref` condition is mandatory — without it, any workflow in the repository with `id-token: write` can request the identity. Bind it to the same full commit SHA callers pin in `uses:`; update caller pins and identity claims together in a reviewed rollout. The subject and `ref` bindings are defense in depth on top of the workflow's own default-branch check.

## GitHub controls

Same as the Vercel guide (`specs/doppler-vercel.md` — branch protection, no `pull_request_target`, SHA-pinned actions, concurrency with cancellation). Workers-specific additions:

- Pin bun in the reusable workflow (`1.3.14` today) and wrangler in each app repository's devDependencies plus lockfile; upgrade either through a reviewed change.
- Review lockfile diffs: dependency code runs during the wrangler-action bundle step, which holds the deploy token.
- A person who can land code on the default branch can deploy the worker. Default-branch protection is the production authorization boundary — there is no other deploy path through this workflow.

## Cloudflare controls

- One account-scoped token for the fleet, stored only in `webops-shared-prod` / `cloudflare-deploy-configs`. A leak is account-wide; rotate from one place.
- Scope the token to the narrowest permissions that deploy (Workers Scripts Edit; add Routes only if needed).
- Remove unnecessary Cloudflare account memberships; deploys should flow through this workflow.

## Migration runbook

1. Put `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in `webops-shared-prod` / `cloudflare-deploy-configs`.
2. Create the production Doppler identity. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read only on `cloudflare-deploy-configs`.
3. Move the worker's runtime secrets into its Doppler project and sync them with `doppler secrets --json | jq -c 'with_entries(.value = .value.computed)' | wrangler secret bulk`. Diff against the live worker before trusting the sync.
4. Confirm the repository has a bun lockfile and a pinned wrangler devDependency; migrate off npm/yarn first if not. Then replace the hand-rolled deploy workflow with the caller shape above, pin the reusable SHA, set the `DOPPLER_PRODUCTION_IDENTITY_ID` var, and remove the `CLOUDFLARE_*` GitHub secrets. Carry any post-deploy step from the old workflow (e.g. `bun run smoke`) into a `needs: deploy` job in the caller — the reusable workflow runs nothing after `wrangler deploy`.
5. Confirm a push to the default branch deploys, and that a pull request run fails at the event check without touching Doppler.

## References

- [Doppler service account identities (OIDC)](https://docs.doppler.com/docs/service-account-identities)
- [Doppler Secrets Fetch Action](https://github.com/DopplerHQ/secrets-fetch-action)
- [Doppler Cloudflare Workers (DIY sync)](https://docs.doppler.com/docs/cloudflare-workers)
- [cloudflare/wrangler-action](https://github.com/cloudflare/wrangler-action)
- [Cloudflare API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/cloudflare-deploy.yml`
- Sibling guide: `specs/doppler-vercel.md`
