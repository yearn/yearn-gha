# Cloudflare Workers Deployment Operating Guide (Doppler)

- **Date:** 2026-08-18. Pull request previews, the build step and monorepo support added 2026-11-19; production isolation restored 2026-11-20.
- **Status:** Implemented in `yearn/yearn-gha`. Complete the per-app migration runbook before cutting a worker over.
- **Context:** Companion to `specs/doppler-vercel.md`. Same threat model (TanStack npm supply-chain compromise of May 2026), same Doppler OIDC pattern, applied to Cloudflare Workers. It matches the reusable workflow in `.github/workflows/cloudflare-deploy.yml`.

## Decision

GitHub Actions builds the worker on the runner and deploys it with wrangler. GitHub Actions authenticates to Doppler with OIDC, so GitHub stores no long-lived Doppler credential. The runner receives an event-specific Cloudflare deploy credential and the app's Doppler config. It pushes the runtime secrets to Cloudflare with `wrangler secret bulk`, then runs `wrangler deploy` (see "Application secrets" below).

**Pull requests deploy previews; a push to the default branch deploys production.** This is the Vercel event model. The deploy environment is derived from the event, never passed by the caller. Fork pull requests and every other event (`pull_request_target`, `workflow_dispatch`, `schedule`, non-default-branch pushes) are rejected before Doppler authentication.

**Previews deploy to a separate Cloudflare account.** A preview build runs pull request code on the runner, in a job that can mint the OIDC token, so pull request code can read whatever the preview identity can read. Cloudflare supports resource-scoped tokens for an existing Worker, but these previews create and delete dynamically named Workers, which requires `Admin` at the Workers-product scope. There is no fixed Worker resource to scope before the PR exists. A preview token for the production account could therefore create, replace, or delete production Workers. The preview account holds no zones and no production workers, so its token can do none of those things in production. See "Previews" below.

Production uses one **account-owned API token per Worker**. The token has `Individual Workers Editor` on that existing Worker and no account-wide Worker, route, zone, or DNS permission. Store `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and the revocation handle `CLOUDFLARE_API_TOKEN_ID` in `<project>` / `cloudflare-deploy-configs`. The Worker and its route or custom-domain connection must be bootstrapped separately; the steady-state token can deploy code and update secrets but cannot create/delete Workers or change the connection.

Preview uses one shared account-owned token in the separate preview account. Store the same three keys in `webops-shared-prod` / `cloudflare-preview-deploy-configs`. It needs Workers-product `Admin` because future `<project>-pr-<number>` resources do not exist when the token is created. It has no zone permission, and the preview account holds no production resources. The reusable workflow selects the project and config from the event — callers do not pass either deploy-config slug.

**The Cloudflare configs are separate from the Vercel `deploy-configs`.** `dopplerhq/secrets-fetch-action` exports every value in the fetched config. One combined config would put the Vercel token on every Cloudflare runner and the Cloudflare token on every Vercel runner. Separate configs keep each platform's blast radius to its own token.

The `project` input names the Doppler project that holds both the Worker-scoped production deploy credential and the app config: `cloudflare-deploy-configs`, `prd`, and `preview`. The production Worker's actual name remains in the app repository's wrangler config. For previews, `project` also forms the dynamic Worker name.

The guide distinguishes three kinds of data:

- **Deployment secret:** `CLOUDFLARE_API_TOKEN`. Long-lived Cloudflare credential even though Doppler authentication is short-lived.
- **Deployment identifiers:** `CLOUDFLARE_ACCOUNT_ID` selects the account; `CLOUDFLARE_API_TOKEN_ID` is retained only so an operator can revoke or rotate the token without rediscovering it. Neither authenticates.
- **Application config:** API tokens, RPC credentials, signing keys and similar values the worker reads at runtime, plus the values a frontend build inlines (`NEXT_PUBLIC_*`, `VITE_*`). They live in `<project>` / `prd` and `<project>` / `preview` and pass through the runner on every deploy.

## Application secrets: synced by the workflow

Doppler has a managed sync integration for Cloudflare **Pages**, but not for Cloudflare **Workers** — Workers is documented under Doppler's DIY syncs (`doppler secrets --json | jq … | wrangler secret bulk`). The workflow runs that flow on each deploy and uses the OIDC identity instead of a service token:

1. **`build` job, `Load app config from Doppler`**, only when the app has a build. `dopplerhq/secrets-fetch-action` v2.0.0 with `auth-method: oidc`, the caller's `build-identity-id`, `doppler-project: ${{ inputs.project }}`, `doppler-config` `prd` or `preview`, and `inject-env-vars: false`. The values are step outputs, not job env.
2. **`build` job, `Build`**. The build is the `build:cloudflare` script in the app's `package.json`, run as `bun run build:cloudflare`; an app without that script falls back to the `build-command` input. The step exports the config inside its own shell and runs the command in `working-directory`. Nothing goes through `GITHUB_ENV`. This job never fetches a Cloudflare token.
3. **`deploy` job, `Load app config from Doppler`**, only with `sync-secrets`, with the caller's `identity-id` (the deploy identity).
4. **`deploy` job, `Push worker runtime secrets to Cloudflare`**, only with `sync-secrets`. A `run` step. Its `env` maps `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the event-specific deploy fetch outputs and `WORKER_SECRETS: ${{ toJSON(steps.app-config.outputs) }}`. It then:
   - removes the Doppler meta keys with `jq 'del(.DOPPLER_PROJECT, .DOPPLER_CONFIG, .DOPPLER_ENVIRONMENT)'`. The fetch action emits these keys as unmasked outputs; they are not worker secrets.
   - fails with `::error::` if zero secrets remain. This catches a wrong `project` or an empty config.
   - pipes the JSON to the workflow-pinned `wrangler secret bulk` on stdin, adding `--name <project>-pr-<number>` for a preview. wrangler prints key names only.

### Workers with no runtime secrets

Some workers have none — every binding they read is declared in the wrangler config
(plain `vars`, a KV namespace, an R2 bucket). `yearn/yearn-uptime-kuma-status`
is the fleet's example: hostnames, a status-page slug and a cache TTL, all
non-secret.

For those, the caller sets `sync-secrets: false`. The app-config fetch and the
push step are skipped, so **no application secret reaches the runner at all**
— a strictly smaller blast radius than a worker that syncs. `project` remains
required because its `cloudflare-deploy-configs` config holds the token for
that one production Worker. The production identity needs read on that
config only.

Do not reach for this to work around an empty or mis-named `prd` config. The
zero-secret check exists to catch exactly that, and `sync-secrets: false`
is an explicit, reviewable assertion that the worker has no runtime secrets —
not a way to silence the check.

### Static sites

A static site (assets only, no worker script) has no runtime: every value it
uses is inlined at build time. Its caller sets `sync-secrets: false`, keeps
`project`, and has a build. The config is fetched for the build and
nothing is pushed to Cloudflare.

Behaviour to know:

- **Zero secrets is an error, not a no-op.** With `sync-secrets` left at `true`, a config that resolves empty fails the deploy. That catches a wrong `project` or an unpopulated config, rather than shipping a worker whose secrets never arrived.
- **First preview deploy.** If the preview worker does not exist yet, `wrangler secret bulk` creates a draft worker in non-interactive mode. `wrangler deploy` then uploads the code. With `sync-secrets: false` there is no draft, so `wrangler deploy` creates the preview worker; wrangler 4.161 then reads it back from `/workers/workers/<name>`, which can briefly answer 10007 "does not exist". The workflow retries a failed deploy. Production Workers must already exist: their individual Editor tokens cannot create them.
- **Existing secrets.** `wrangler deploy` keeps the secrets already on the worker.
- **Additive.** `secret bulk` adds and updates keys. It does not delete a key removed from Doppler. Remove stale keys by hand with `wrangler secret delete`.
- **Everything in the config is pushed.** With both a build and `sync-secrets`, build-only values (`NEXT_PUBLIC_*`) are also stored as worker secrets. They are public by nature; the cost is noise in `wrangler secret list`.
- **Masking.** The fetch action log-masks every value except values with Doppler visibility `Unmasked`. Set app secrets to Masked.

## Previews

A pull request from a branch of the caller repository deploys its own worker, `<project>-pr-<number>`, to the preview account, and redeploys it on every push. Closing the pull request deletes it.

- **Deploy.** The `build` job uploads the assets directory and wrangler's bundle as an artifact. The `deploy` job runs `wrangler deploy <bundle> --no-bundle --env preview --name <project>-pr-<number>` with the wrangler pinned in the workflow and the wrangler config from the caller's default branch, never the pull request's. That config must define a `preview` environment that is safe outside production: `workers_dev: true`, `routes: []` (the deploy job fails on any preview route), no cron triggers, and bindings that do not point at production data. Top-level settings that wrangler inherits (`triggers`, `assets`, `main`) apply to the preview unless the environment overrides them. A pull request's own config changes, including the first config of a migration, reach previews only after they merge.
- **Secrets.** The workflow pushes `<project>` / `preview` with `wrangler secret bulk --name <project>-pr-<number>`. `--env` is deliberately absent there: wrangler's secret commands append the environment to `--name` (`<name>-preview`), while `wrangler deploy --env preview --name <name>` deploys to `<name>`. Read from the wrangler 4.140.0 and 4.165.0 sources; recheck when a caller pins a wrangler outside that range.
- **Naming.** `project` names the preview worker. In a pull request run the caller workflow comes from the pull request, so the input is untrusted: the workflow rejects a name that is not lowercase letters, digits and dashes, at most 63 characters, before any credential is fetched.
- **URL.** The `deployment-url` output is the worker's `workers.dev` URL in the preview account. A `comment` job posts it on the pull request, one comment per project, updated in place. That job holds `pull-requests: write` and nothing else, and never checks out the repository.
- **Cleanup.** On `pull_request` `closed` a `delete` job removes the worker through the Cloudflare API (`DELETE /accounts/{id}/workers/scripts/{name}?force=true`). It has no checkout and no install. The caller must subscribe to the `closed` type, or previews accumulate against the account's script limit.
- **Fork pull requests** are rejected: no OIDC token is issued to them.

What a pull request can reach: the app's `preview` config, through the preview build identity. It cannot reach the preview token, `cloudflare-deploy-configs` or `<project>` / `prd`: those are readable only by the deploy identities, whose subjects name the `cloudflare-preview` / `cloudflare-production` GitHub environments that only the reusable workflow's `deploy` and `delete` jobs use. Preview URLs are public; put Cloudflare Access in front of the preview account's `workers.dev` hostnames if an app's preview must not be.

## What this design protects—and what it does not

Provided controls:

- No static Doppler credential in GitHub; OIDC tokens are short-lived.
- Each production Cloudflare token is isolated to one existing Worker and stored in that Worker's Doppler project. The preview token is stored separately and has authority only in the isolated preview account. Neither config contains Vercel credentials.
- Worker runtime secrets have one source of truth (`<project>` / `prd`, `<project>` / `preview`) and reach Cloudflare on every deploy, with no operator step.
- One trusted reusable workflow implements event checks, action pins, the bun and node pins, and validation.
- Callers pin the reusable workflow to a full commit SHA; Doppler identities bind `job_workflow_ref` to that SHA.
- Cloudflare tokens are fetched only in the `deploy` and `delete` jobs, which run no repository code: no pull request checkout, no install, no repository scripts, wrangler pinned by this workflow, wrangler config from the default branch.
- Pull requests reach only the `preview` config; fork pull requests and every other event reach nothing.

Not eliminated:

- `CLOUDFLARE_API_TOKEN` is still a long-lived credential exposed to the pinned wrangler on the deploy runner. A production compromise reaches that one Worker; the preview token is Workers-product Admin in the preview account, so a compromise of the deploy job or of wrangler itself reaches every Worker there. A separate preview account bounds that.
- **Pull request code can read the `preview` config.** The build job runs the pull request's install and build and can mint the preview build identity's OIDC token. Keep production values out of `preview` configs.
- **Pull request code runs on Cloudflare.** The preview worker executes the pull request's bundle with its preview secrets and the default branch's bindings. Do not bind production data in the `preview` environment.
- **The build sees the app config.** With a build, the whole `prd` (or `preview`) config is the build's environment, and the artifact (kept one day, readable by repository readers) contains whatever the build inlines. Do not inline server-only secrets.
- **The deploy job installs wrangler from npm** at an exact version with `--ignore-scripts`; its transitive dependencies resolve from their published ranges. Upgrade `WRANGLER_VERSION` through a reviewed change.
- **A missing `preview` environment is only a wrangler warning.** `wrangler deploy --env preview` falls back to the top-level config when the environment is absent. Top-level routes then fail the deploy job's route check, but a cron trigger would run.
- **Stale secrets stay.** `secret bulk` is additive. A key removed from Doppler stays on the worker until an operator deletes it.
- **Secrets land before code.** `secret bulk` creates a worker version with the new secrets before `wrangler deploy` uploads the new code. For a short window the old code runs with the new secrets. Keep secret changes backward compatible across one deploy.
- OIDC policy is an authorization boundary only when all relevant claims are checked; identity IDs are public metadata.

## Target architecture

- A small caller workflow in each repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- A pull request deploys a preview worker; a push to the caller repository's default branch runs the production `wrangler deploy`. Everything else is rejected before Doppler authentication.
- `build` job: asserts the caller ships `bun.lock` or `bun.lockb` (in `working-directory`, else the repository root), installs with `bun install --frozen-lockfile`, fetches the app config with the build identity and runs the app's build if there is one, bundles the worker with the app's wrangler (`wrangler deploy --dry-run --outdir`), and uploads the assets directory and bundle.
- `deploy` job (`cloudflare-preview` / `cloudflare-production` environment): checks out only the wrangler config from the default branch, downloads the artifact, installs `wrangler@WRANGLER_VERSION`, fetches the app config (with `sync-secrets`) and `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` with the deploy identity, pushes secrets with `wrangler secret bulk`, and runs `wrangler deploy <bundle> --no-bundle`. A first deploy that reads the new worker back as missing (10007) is retried up to three times, a minute apart.
- Post-deploy verification (smoke tests) stays in the caller as a `needs: deploy` job — the reusable workflow is deploy-only.
- Output: `deployment-url` — the production or preview URL parsed by the action. It is empty for a worker with no `workers.dev` subdomain or route, and is only the first target for a multi-route worker.

### Caller shape

```yaml
name: Deploy to Cloudflare Workers

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  push:
    branches: [main] # or master — match the repository default branch

permissions:
  contents: read
  id-token: write
  pull-requests: write

cache-mode: none

jobs:
  deploy:
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha> # full commit SHA only
    with:
      project: <doppler-project>
      identity-id: ${{ github.event_name == 'pull_request' && vars.DOPPLER_CF_PREVIEW_IDENTITY_ID || vars.DOPPLER_CF_PRODUCTION_IDENTITY_ID }}
```

A production-only caller drops the `pull_request` trigger and passes its production identity. It still grants `pull-requests: write`, which the workflow's `comment` job requests: a called workflow cannot request a permission its caller does not grant.

Repository variables: `DOPPLER_CF_PREVIEW_IDENTITY_ID` and `DOPPLER_CF_PRODUCTION_IDENTITY_ID`. The Cloudflare identities must not reuse the Vercel service account: Doppler grants permissions to a service account, so reuse would give its pull-request identity access to the production configs granted for Cloudflare. Identity IDs are not secrets.

Do not set `environment:` on the caller job. It changes the OIDC subject to `repo:<org>/<repo>:environment:<name>`, which no identity here matches. Do not add a caller-level `concurrency` block with `cancel-in-progress: true` either; it would cancel a production upload.

### Workflow inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `project` | yes | — | Doppler project holding the Worker-scoped production deploy config and app configs (`prd`, `preview`). Also names the preview worker `<project>-pr-<number>`. |
| `sync-secrets` | no | `true` | Whether the worker has runtime secrets to push. `false` skips the push; without a build it also skips the config fetch. |
| `build-command` | no | — | Fallback build command for an app whose `package.json` has no `build:cloudflare` script; ignored when the script exists. Runs in `working-directory` with the Doppler config as its environment. |
| `working-directory` | no | `.` | Directory holding the wrangler config. |
| `identity-id` | yes | — | Doppler service-account identity for the event: preview for a pull request, production for a push to the default branch. |

Output: `deployment-url` (production or preview URL).

### Rejected alternatives

- **Previews in the production account.** One account and one token is simpler, but any same-repository pull request could then reach a token that edits every production worker and attaches routes in production zones.
- **`wrangler versions upload` with preview aliases.** A preview version is a version of the production worker: it keeps that worker's secrets for every key the upload does not override. Cloudflare also generates no version URL for a worker that defines a Durable Object, as OpenNext's cache setup does.
- **A second reusable workflow for previews.** It would leave production-only callers untouched, but duplicate every security-relevant step (lockfile assert, wrangler probe, config fetch, build). One workflow keeps them in one place; the cost is `pull-requests: write` in every caller.
- **Cloudflare Workers Previews (`wrangler preview`).** Newer than the per-pull-request worker and not evaluated hands-on. It needs wrangler 4.136 or later in every caller, while `deploy --env preview --name` uses the two commands production already runs. Revisit if per-pull-request workers press against the preview account's script limit.
- **Cloudflare Pages.** The fleet's Cloudflare footprint is Workers; Cloudflare's own direction folds Pages into Workers (static assets on Workers). Doppler's managed Pages sync does not apply to Workers projects.
- **One account-wide production token.** Cloudflare supports `Editor` scoped to an existing individual Worker. A shared product-scoped token would let a compromise in one main-branch deploy alter every production Worker, so production tokens are per Worker. This does not solve preview creation and cleanup, which require Workers-product `Admin` because the Worker names do not exist before each PR.
- **One token per preview Worker or a name-prefix token.** Cloudflare cannot scope a token to a Worker that does not exist yet or to a future name prefix. A single Workers-product `Admin` token is therefore used only in an account that contains previews and no production resource.
- **`workflow_dispatch` manual deploys.** Same rationale as Vercel: broadens deployment authority and bypasses the event gate. Add a separately reviewed, approval-gated manual path only if an operational need emerges.
- **Out-of-band operator sync (previous design).** An operator ran the DIY `wrangler secret bulk` flow by hand with a config-scoped Doppler token. Doppler and the worker drifted between manual runs, and a deploy gave no guarantee that the worker had the current secrets. Superseded by the in-workflow sync.
- **`wrangler deploy --secrets-file`.** Atomic with the deploy, so it closes the secrets-before-code window. It requires writing the secrets to a file on disk in the deploy step. Revisit with the workflow's `WRANGLER_VERSION`.

## Doppler configuration

Service Account Identities require a Doppler Team or Enterprise workplace.

### Deployment configs

Create one production deploy config per Worker:

- `<project>` / `cloudflare-deploy-configs`: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_API_TOKEN_ID` for the production account. Use an account-owned token with `Individual Workers Editor` scoped to that existing Worker. Grant no zone or route permission. Creating the Worker and attaching or changing a route/custom domain require a separately controlled bootstrap credential; after the connection exists, Cloudflare permits new versions and secret updates with only Worker `Editor` as long as the deploy does not change that connection.

Keep one preview deploy config in the existing shared project:

- `webops-shared-prod` / `cloudflare-preview-deploy-configs`: the same three keys for the preview account. The account-owned API token needs `Admin` at the Workers-product scope because the workflow creates a Worker for each PR and deletes it when the PR closes. Grant no zone permissions and keep all production resources out of this account.

Set each token's Doppler visibility to **Masked** — the fetch action registers GitHub log redaction only for values that are not Unmasked. Keep only these three values in each config: every value in it is fetched onto the runner as a step output. Do not add Vercel credentials here, and do not add Cloudflare credentials to the Vercel `deploy-configs`.

### Application project

One Doppler project per worker, passed as the `project` input. `prd` holds the production config, `preview` the pull request config. The workflow pushes every value in the selected config to the worker with `wrangler secret bulk` on each deploy (unless `sync-secrets` is false) and exports it to the build. Set each value to Masked.

A worker with no runtime secrets and no build still needs an application project for its Worker-scoped `cloudflare-deploy-configs`. Its caller sets `sync-secrets: false`, and its production identity is granted read on that config only. Do not create an empty `prd` config for it.

### Service accounts, identities, and OIDC

Doppler grants access per service account, not per identity. Two identities on one service account can read the same configs, so preview and production need **separate service accounts**:

| Service account | Identity subject | Reads |
| --------------- | ---------------- | ----- |
| Production deploy | `repo:<org>/<repo>:environment:cloudflare-production` | `<project>` / `cloudflare-deploy-configs`, `<project>` / `prd` |
| Production build | `repo:<org>/<repo>:ref:refs/heads/<default-branch>` | `<project>` / `prd` |
| Preview deploy | `repo:<org>/<repo>:environment:cloudflare-preview` | `webops-shared-prod` / `cloudflare-preview-deploy-configs`, `<project>` / `preview` |
| Preview build | `repo:<org>/<repo>:pull_request` | `<project>` / `preview` |

The GitHub environment on the `deploy` and `delete` jobs is what separates the subjects: the `build` job, which runs repository code, cannot mint an `environment:` subject. A caller job that sets the same environment itself fails the `job_workflow_ref` claim.

For a `sync-secrets: false` caller with no build, grant only its per-project production deploy config; preview still needs the shared preview deploy config if the repository deploys previews. Do not reuse a repository's Vercel service account for either identity: its pull-request identity would gain whatever production access the account is granted here.

Each identity uses:

- Provider: GitHub (`https://token.actions.githubusercontent.com`)
- Audience matching the action's token (verify against a real token; usually `https://github.com/<org>`)
- Subject as in the table (or the immutable-format equivalent)
- Exact additional claims. Production deploy and build: `event_name=push`, `ref=refs/heads/<default-branch>`. Preview deploy and build: `event_name=pull_request`. All: `job_workflow_ref=yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha>`
- No wildcards on claims.

The `job_workflow_ref` condition is mandatory — without it, any workflow in the repository with `id-token: write` can request the identity. Bind it to the same full commit SHA callers pin in `uses:`; update caller pins and identity claims together in a reviewed rollout. All four share one `job_workflow_ref`; the subject and `event_name` claims, and the separate service accounts, are what keep a pull request away from the deploy credentials.

## GitHub controls

Same as the Vercel guide (`specs/doppler-vercel.md` — branch protection, no `pull_request_target`, SHA-pinned actions). Workers-specific additions:

- The reusable workflow owns deploy serialization: one job-level concurrency group per worker (repository, `project`, `working-directory`, and the pull request number or `production`). Production runs are not cancelled — a cancelled `wrangler deploy` has no defined outcome mid-upload, and GitHub supersedes the queued run anyway, so the newest commit still wins. Preview runs are, because the cancelling run redeploys. The group is per worker, not per repository, so a multi-project caller's jobs do not supersede each other while queued. Callers need no concurrency block.
- Callers grant `contents: read`, `id-token: write` and `pull-requests: write`. Only the `comment` job uses the last one.
- Pin bun, node and the deploy-side wrangler in the reusable workflow (`1.4.4`, `22` and `WRANGLER_VERSION` today); the app's own wrangler only bundles in the build job. Upgrade through a reviewed change.
- Review lockfile diffs: dependency code runs in the build job, which reaches the app config but no deploy token.
- A person who can land code on the default branch can deploy the worker. Default-branch protection is the production authorization boundary. A person who can push a branch and open a pull request can deploy a preview only in the isolated preview account.

## Cloudflare controls

- Two accounts: production, which holds the zones and production workers, and preview, which holds only pull request workers. Never add a zone or a production resource to the preview account.
- One account-owned token per production Worker, with `Individual Workers Editor`, stored only in that Worker's Doppler project. It cannot create/delete Workers or alter routes and custom domains.
- One account-owned token for the preview account, stored only in `webops-shared-prod` / `cloudflare-preview-deploy-configs`. It has Workers-product `Admin`, so a leak compromises every preview Worker; rotate it from one place.
- Use a separately controlled production bootstrap credential to create a Worker and attach or change routes/custom domains. The deploy token gets no route or zone permission.
- Remove unnecessary Cloudflare account memberships; deploys should flow through this workflow.

## Migration runbook

1. Bootstrap the production Worker and its routes/custom domains. Create an `Individual Workers Editor` token scoped to that Worker and put `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_API_TOKEN_ID` in `<project>` / `cloudflare-deploy-configs`. Put the corresponding preview-account values in `webops-shared-prod` / `cloudflare-preview-deploy-configs`; the migration script creates both token types.
2. Create the production service account and identity. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read only on `<project>` / `cloudflare-deploy-configs` and `<project>` / `prd`.
3. Create the preview service account and identity (subject `repo:<org>/<repo>:pull_request`, `event_name=pull_request`, the same `job_workflow_ref`). Grant read only on `webops-shared-prod` / `cloudflare-preview-deploy-configs` and `<project>` / `preview`.
4. Create the worker's Doppler project and populate `prd` (and `preview`). Before the first production run, diff the Doppler key set against `wrangler secret list` on the live worker: the sync adds and overwrites keys but deletes none.
5. Confirm the repository has a bun lockfile and a pinned wrangler devDependency; migrate off npm/yarn first if not. For previews, add the `preview` environment to the wrangler config. Then add the caller shape above, pass `project`, pin the reusable SHA, set the identity variables, and remove any `CLOUDFLARE_*` GitHub secrets. Carry any post-deploy step from an old workflow (e.g. `bun run smoke`) into a `needs: deploy` job in the caller — the reusable workflow runs nothing after `wrangler deploy`.
6. Confirm a push to the default branch deploys production, a pull request gets a preview URL comment, closing it deletes the preview worker, and a run on any other event fails at the event check without touching Doppler.

A caller pinned to a SHA from before previews keeps working unchanged. When its pin moves to a SHA with previews, add `pull-requests: write` to its permissions in the same change; `bump-gha-consumers` does. Without it GitHub is expected to reject the run at startup — confirm that on the first bumped caller.

## References

- [Doppler service account identities (OIDC)](https://docs.doppler.com/docs/service-account-identities)
- [Doppler Secrets Fetch Action](https://github.com/DopplerHQ/secrets-fetch-action)
- [Doppler Cloudflare Workers (DIY sync)](https://docs.doppler.com/docs/cloudflare-workers)
- [cloudflare/wrangler-action](https://github.com/cloudflare/wrangler-action)
- [wrangler secret bulk](https://developers.cloudflare.com/workers/wrangler/commands/#secret)
- [Wrangler environments](https://developers.cloudflare.com/workers/wrangler/environments/)
- [Cloudflare API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
- [Workers roles and resource scopes](https://developers.cloudflare.com/workers/authorization/workers/)
- [Create account-owned API tokens](https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/create/)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/cloudflare-deploy.yml`
- Sibling guide: `specs/doppler-vercel.md`
