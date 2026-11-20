# Cloudflare Workers Deployment Operating Guide (Doppler)

- **Date:** 2026-08-18. Pull request previews, the build step and monorepo support added 2026-11-19; production isolation restored 2026-11-20.
- **Status:** Implemented in `yearn/yearn-gha`. Complete the per-app migration runbook before cutting a worker over.
- **Context:** Companion to `specs/doppler-vercel.md`. Same threat model (TanStack npm supply-chain compromise of May 2026), same Doppler OIDC pattern, applied to Cloudflare Workers. It matches the reusable workflow in `.github/workflows/cloudflare-deploy.yml`.

## Decision

GitHub Actions builds the worker on the runner and deploys it with wrangler. GitHub Actions authenticates to Doppler with OIDC, so GitHub stores no long-lived Doppler credential. The runner receives the shared Cloudflare deploy credentials and the app's Doppler config. It pushes the runtime secrets to Cloudflare with `wrangler secret bulk`, then runs `wrangler deploy` (see "Application secrets" below).

**Pull requests deploy previews; a push to the default branch deploys production.** This is the Vercel event model. The deploy environment is derived from the event, never passed by the caller. Fork pull requests and every other event (`pull_request_target`, `workflow_dispatch`, `schedule`, non-default-branch pushes) are rejected before Doppler authentication.

**Previews deploy to a separate Cloudflare account.** A preview build runs pull request code on the runner, in a job that can mint the OIDC token, so pull request code can read whatever the preview identity can read. Cloudflare supports resource-scoped tokens for an existing Worker, but these previews create and delete dynamically named Workers, which requires `Admin` at the Workers-product scope. There is no fixed Worker resource to scope before the PR exists. A preview token for the production account could therefore create, replace, or delete production Workers. The preview account holds no zones and no production workers, so its token can do none of those things in production. See "Previews" below.

Each account has one **shared account-owned Cloudflare API token**. Store `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` for the production account in `webops-shared-prod` / `cloudflare-deploy-configs`, and for the preview account in `webops-shared-prod` / `cloudflare-preview-deploy-configs`. The reusable workflow hardcodes the slugs in its workflow-level `env` and picks one by event — callers do not pass them. Each token is scoped to the Workers product in only its own account.

**The Cloudflare configs are separate from the Vercel `deploy-configs`.** `dopplerhq/secrets-fetch-action` exports every value in the fetched config. One combined config would put the Vercel token on every Cloudflare runner and the Cloudflare token on every Vercel runner. Separate configs keep each platform's blast radius to its own token.

There is no per-app Doppler deploy config. Vercel needs a per-app `VERCEL_PROJECT_ID`; a worker's identity is its name in the app repository's wrangler config. The `project` input names the Doppler project that holds the app's config: `prd` for production, `preview` for pull requests.

The guide distinguishes three kinds of data:

- **Deployment secret:** `CLOUDFLARE_API_TOKEN`. Long-lived Cloudflare credential even though Doppler authentication is short-lived.
- **Deployment identifier:** `CLOUDFLARE_ACCOUNT_ID`. Selects the account; configuration, not authentication.
- **Application config:** API tokens, RPC credentials, signing keys and similar values the worker reads at runtime, plus the values a frontend build inlines (`NEXT_PUBLIC_*`, `VITE_*`). They live in `<project>` / `prd` and `<project>` / `preview` and pass through the runner on every deploy.

## Application secrets: synced by the workflow

Doppler has a managed sync integration for Cloudflare **Pages**, but not for Cloudflare **Workers** — Workers is documented under Doppler's DIY syncs (`doppler secrets --json | jq … | wrangler secret bulk`). The workflow runs that flow on each deploy and uses the OIDC identity instead of a service token:

1. **`Load app config from Doppler`** (step `app-config`). `dopplerhq/secrets-fetch-action` v2.0.0 with `auth-method: oidc`, the caller's `identity-id`, `doppler-project: ${{ inputs.project }}`, `doppler-config` `prd` or `preview`, and `inject-env-vars: false`. The values are step outputs, not job env. It runs when `project` is set and either `sync-secrets` is true or the app has a build.
2. **`Build`**, only when the app has a build. The build is the `build:cloudflare` script in the app's `package.json`, run as `bun run build:cloudflare`; an app without that script falls back to the `build-command` input. The step exports the config inside its own shell and runs the command in `working-directory`. Nothing goes through `GITHUB_ENV`, so later steps — wrangler-action included — do not inherit the values. The Cloudflare token is fetched after this step.
3. **`Push worker runtime secrets to Cloudflare`**, only with `sync-secrets`. A `run` step. Its `env` maps `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from the shared fetch outputs and `WORKER_SECRETS: ${{ toJSON(steps.app-config.outputs) }}`. It then:
   - removes the Doppler meta keys with `jq 'del(.DOPPLER_PROJECT, .DOPPLER_CONFIG, .DOPPLER_ENVIRONMENT)'`. The fetch action emits these keys as unmasked outputs; they are not worker secrets.
   - fails with `::error::` if zero secrets remain. This catches a wrong `project` or an empty config.
   - pipes the JSON to `bun run wrangler secret bulk` on stdin, adding `--name <project>-pr-<number>` for a preview. wrangler prints key names only.

### Workers with no runtime secrets

Some workers have none — every binding they read is declared in the wrangler config
(plain `vars`, a KV namespace, an R2 bucket). `yearn/yearn-uptime-kuma-status`
is the fleet's example: hostnames, a status-page slug and a cache TTL, all
non-secret.

For those, the caller sets `sync-secrets: false` and omits `project`. Both the
config fetch and the push step are skipped, so **no application
secret reaches the runner at all** — a strictly smaller blast radius than a
worker that syncs. The deploy identity then needs read on
`webops-shared-prod` / `cloudflare-deploy-configs` only.

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
- **First deploy.** If the worker does not exist yet, `wrangler secret bulk` creates a draft worker in non-interactive mode. `wrangler deploy` then uploads the code. Every new pull request preview starts this way. With `sync-secrets: false` there is no draft, so `wrangler deploy` creates the worker; wrangler 4.161 then reads it back from `/workers/workers/<name>`, which answers 10007 "does not exist" for a few seconds, and does not retry a 404. The workflow runs the deploy a second time when the first fails.
- **Existing secrets.** `wrangler deploy` keeps the secrets already on the worker.
- **Additive.** `secret bulk` adds and updates keys. It does not delete a key removed from Doppler. Remove stale keys by hand with `wrangler secret delete`.
- **Everything in the config is pushed.** With both a build and `sync-secrets`, build-only values (`NEXT_PUBLIC_*`) are also stored as worker secrets. They are public by nature; the cost is noise in `wrangler secret list`.
- **Masking.** The fetch action log-masks every value except values with Doppler visibility `Unmasked`. Set app secrets to Masked.

## Previews

A pull request from a branch of the caller repository deploys its own worker, `<project>-pr-<number>`, to the preview account, and redeploys it on every push. Closing the pull request deletes it.

- **Deploy.** `wrangler deploy --env preview --name <project>-pr-<number>`. The app's wrangler config must define a `preview` environment that is safe outside production: `workers_dev: true`, `routes: []`, no cron triggers, and bindings that point at resources in the preview account. Top-level settings that wrangler inherits (`routes`, `triggers`, `assets`, `main`) apply to the preview unless the environment overrides them.
- **Secrets.** The workflow pushes `<project>` / `preview` with `wrangler secret bulk --name <project>-pr-<number>`. `--env` is deliberately absent there: wrangler's secret commands append the environment to `--name` (`<name>-preview`), while `wrangler deploy --env preview --name <name>` deploys to `<name>`. Read from the wrangler 4.140.0 and 4.165.0 sources; recheck when a caller pins a wrangler outside that range.
- **Naming.** `project` names the preview worker. In a pull request run the caller workflow comes from the pull request, so the input is untrusted: the workflow rejects a name that is not lowercase letters, digits and dashes, at most 63 characters, before any credential is fetched.
- **URL.** The `deployment-url` output is the worker's `workers.dev` URL in the preview account. A `comment` job posts it on the pull request, one comment per project, updated in place. That job holds `pull-requests: write` and nothing else, and never checks out the repository.
- **Cleanup.** On `pull_request` `closed` a `delete` job removes the worker through the Cloudflare API (`DELETE /accounts/{id}/workers/scripts/{name}?force=true`). It has no checkout and no install. The caller must subscribe to the `closed` type, or previews accumulate against the account's script limit.
- **Fork pull requests** are rejected: no OIDC token is issued to them.

What a pull request can reach: the preview account's token and the app's `preview` config. It cannot reach `cloudflare-deploy-configs` or `<project>` / `prd`, because those are readable only by the production service account, whose identity is bound to a push to the default branch. Preview URLs are public; put Cloudflare Access in front of the preview account's `workers.dev` hostnames if an app's preview must not be.

## What this design protects—and what it does not

Provided controls:

- No static Doppler credential in GitHub; OIDC tokens are short-lived.
- The shared Cloudflare tokens are stored once each, in their own Doppler configs, isolated from the Vercel credentials and from each other.
- Worker runtime secrets have one source of truth (`<project>` / `prd`, `<project>` / `preview`) and reach Cloudflare on every deploy, with no operator step.
- One trusted reusable workflow implements event checks, action pins, the bun and node pins, and validation.
- Callers pin the reusable workflow to a full commit SHA; Doppler identities bind `job_workflow_ref` to that SHA.
- Production credentials are reachable only from a push to the default branch. Pull requests reach only the preview account and the `preview` config; fork pull requests and every other event reach nothing.

Not eliminated:

- `CLOUDFLARE_API_TOKEN` is still a long-lived credential exposed to wrangler on the runner. Compromise reaches every Worker covered by that account's product-scoped token.
- **Pull request code can read the preview token and the `preview` config.** A same-repository pull request — a poisoned dependency bump included — runs its install and build in a job that can mint the preview identity's OIDC token. The damage is bounded by what the preview account holds: other previews and their secrets. Keep production resources out of that account and production values out of `preview` configs.
- **The build runs on the runner.** Unlike Vercel remote builds, the app is built and bundled on the runner, so third-party dependency code executes during the deploy. The workflow narrows the exposure: the app's own `bun install` runs before the Doppler fetches, and all values are read as step outputs (`inject-env-vars: false`) rather than injected into the job environment, so that install's scripts never see them; after the fetches, only the build step, the validate step and the push step (explicit env mapping) and the wrangler-action inputs receive them. The workflow also passes no `wranglerVersion`, and before any credential is fetched runs `bun run wrangler --version` in `working-directory` — the exact command wrangler-action runs for a bun caller to decide whether to install — failing unless it exits 0 and stdout carries a parseable wrangler version, the same test wrangler-action applies, so wrangler-action runs no install of its own in the step that holds the token. `packageManager: bun` is passed explicitly, because wrangler-action otherwise detects the package manager from the lockfile in its working directory and falls back to npm for a workspace package. Residual risk: dependency code that wrangler-action bundles still runs in that step, and wrangler runs in the push step; a compromised dependency can exfiltrate the token there. Mitigation is dependency hygiene (lockfiles, review of lockfile diffs), not this workflow.
- **The build sees the app config.** With a build, the whole `prd` (or `preview`) config is the build's environment, so the build toolchain and its dependencies can read it.
- **App secrets land on the deploy runner.** They are step outputs of `app-config` and go to the build step and one `run` step through explicit env. A compromised dependency in the build, the push step or the wrangler-action step can read them.
- **Step ordering is not an authorization boundary.** `id-token: write` is job-scoped, so any code that runs earlier in the job can mint the same OIDC token and fetch from Doppler itself. Running the install first keeps the fetched values out of the install step's environment; it does not keep dependency code away from the credential or the app secrets.
- **A missing `preview` environment is only a wrangler warning.** `wrangler deploy --env preview` falls back to the top-level config when the environment is absent. In the preview account a production route then fails the deploy, but a cron trigger would run. The workflow does not parse the wrangler config to check.
- **Stale secrets stay.** `secret bulk` is additive. A key removed from Doppler stays on the worker until an operator deletes it.
- **Secrets land before code.** `secret bulk` creates a worker version with the new secrets before `wrangler deploy` uploads the new code. For a short window the old code runs with the new secrets. Keep secret changes backward compatible across one deploy.
- OIDC policy is an authorization boundary only when all relevant claims are checked; identity IDs are public metadata.

## Target architecture

- A small caller workflow in each repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- A pull request deploys a preview worker; a push to the caller repository's default branch runs the production `wrangler deploy`. Everything else is rejected before Doppler authentication.
- The workflow asserts the caller ships `bun.lock` or `bun.lockb`, installs dependencies with `bun install --frozen-lockfile` (the fleet standardizes on bun; the version is pinned in `.github/workflows/cloudflare-deploy.yml`), probes that the local wrangler runs, fetches the app config and runs the app's build if there is one, then fetches `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as step outputs and validates them. It then pushes the runtime secrets with `bun run wrangler secret bulk` and runs `wrangler deploy` via `cloudflare/wrangler-action`. No `wranglerVersion` is passed: wrangler-action uses the wrangler the app repository already installed, so the wrangler pin is the app's lockfile.
- **Precondition: the caller repository ships a bun lockfile** (`bun.lock` or `bun.lockb`) and a wrangler devDependency. The lockfile is looked up in `working-directory` first (a standalone package), then at the repository root (a workspace), and the install runs where it is found. A missing lockfile fails an explicit check before the install: `--frozen-lockfile` only rejects a lockfile that would change, so with none present bun resolves every dependency — wrangler included — fresh from the registry. A stale lockfile fails the frozen install. A lockfile that never lists a runnable wrangler fails the `bun run wrangler --version` probe (must exit 0 and print a wrangler version). All three run before Doppler is reached.
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
| `project` | when `sync-secrets` is true, and for every pull request | — | Doppler project holding the app's config (`prd`, `preview`). Also names the preview worker `<project>-pr-<number>`. |
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
- **Per-app Cloudflare API tokens.** Cloudflare now supports `Editor` scoped to an existing individual Worker, which can further reduce the steady-state production blast radius. This reusable workflow keeps one shared production token for fleet operations; adopting per-worker tokens would require a trusted mapping from `project` to token. It does not solve preview creation and cleanup, which require Workers-product `Admin` because the Worker names do not exist before each PR.
- **Per-app Doppler deploy config.** Nothing app-specific to store for the deploy — the worker name lives in the wrangler config. An empty per-app fetch is pure surface.
- **`workflow_dispatch` manual deploys.** Same rationale as Vercel: broadens deployment authority and bypasses the event gate. Add a separately reviewed, approval-gated manual path only if an operational need emerges.
- **Out-of-band operator sync (previous design).** An operator ran the DIY `wrangler secret bulk` flow by hand with a config-scoped Doppler token. Doppler and the worker drifted between manual runs, and a deploy gave no guarantee that the worker had the current secrets. Superseded by the in-workflow sync.
- **`wrangler deploy --secrets-file`.** Atomic with the deploy, so it closes the secrets-before-code window. It requires writing the secrets to a file on disk in the wrangler-action step, and a per-app check that the app's pinned wrangler supports the flag. Revisit when the fleet pins a wrangler version that ships it.

## Doppler configuration

Service Account Identities require a Doppler Team or Enterprise workplace.

### Shared deployment project

In the existing `webops-shared-prod` Doppler project, keep two environments / configs:

- `cloudflare-deploy-configs`: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` of the production account. Use an account-owned API token with `Editor` at the Workers-product scope, plus Workers Routes Write for each affected zone when workers declare routes. Creating the production Worker for the first time requires a separately controlled bootstrap with Workers-product `Admin`; do not leave that broader permission on the steady-state token.
- `cloudflare-preview-deploy-configs`: the same two keys for the preview account. The account-owned API token needs `Admin` at the Workers-product scope because the workflow creates a Worker for each PR and deletes it when the PR closes. Grant no zone permissions and keep all production resources out of this account.

Set each token's Doppler visibility to **Masked** — the fetch action registers GitHub log redaction only for values that are not Unmasked. Keep only those two values in each config: every value in it is fetched onto the runner as a step output. Do not add the Vercel credentials here, and do not add the Cloudflare credentials to the Vercel `deploy-configs`.

### Application project

One Doppler project per worker, passed as the `project` input. `prd` holds the production config, `preview` the pull request config. The workflow pushes every value in the selected config to the worker with `wrangler secret bulk` on each deploy (unless `sync-secrets` is false) and exports it to the build. Set each value to Masked.

A worker with no runtime secrets and no build needs no application project at all: its caller sets `sync-secrets: false`, and its identity is granted read on `webops-shared-prod` / `cloudflare-deploy-configs` only. Do not create an empty `prd` config for it.

### Service accounts, identities, and OIDC

Doppler grants access per service account, not per identity. Two identities on one service account can read the same configs, so preview and production need **separate service accounts**:

| Service account | Identity subject | Reads |
| --------------- | ---------------- | ----- |
| Production | `repo:<org>/<repo>:ref:refs/heads/<default-branch>` | `webops-shared-prod` / `cloudflare-deploy-configs`, `<project>` / `prd` |
| Preview | `repo:<org>/<repo>:pull_request` | `webops-shared-prod` / `cloudflare-preview-deploy-configs`, `<project>` / `preview` |

For a `sync-secrets: false` caller with no build, grant the matching shared config only. Do not reuse a repository's Vercel service account for either identity: its pull-request identity would gain whatever production access the account is granted here.

Each identity uses:

- Provider: GitHub (`https://token.actions.githubusercontent.com`)
- Audience matching the action's token (verify against a real token; usually `https://github.com/<org>`)
- Subject as in the table (or the immutable-format equivalent)
- Exact additional claims. Production: `event_name=push`, `ref=refs/heads/<default-branch>`. Preview: `event_name=pull_request`. Both: `job_workflow_ref=yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<approved-sha>`
- No wildcards on claims.

The `job_workflow_ref` condition is mandatory — without it, any workflow in the repository with `id-token: write` can request the identity. Bind it to the same full commit SHA callers pin in `uses:`; update caller pins and identity claims together in a reviewed rollout. Preview and production share one `job_workflow_ref`; the subject and `event_name` claims, and the separate service accounts, are what keep a pull request away from production.

## GitHub controls

Same as the Vercel guide (`specs/doppler-vercel.md` — branch protection, no `pull_request_target`, SHA-pinned actions). Workers-specific additions:

- The reusable workflow owns deploy serialization: one job-level concurrency group per worker (repository, `project`, `working-directory`, and the pull request number or `production`). Production runs are not cancelled — a cancelled `wrangler deploy` has no defined outcome mid-upload, and GitHub supersedes the queued run anyway, so the newest commit still wins. Preview runs are, because the cancelling run redeploys. The group is per worker, not per repository, so a multi-project caller's jobs do not supersede each other while queued. Callers need no concurrency block.
- Callers grant `contents: read`, `id-token: write` and `pull-requests: write`. Only the `comment` job uses the last one.
- Pin bun and node in the reusable workflow (`1.4.4` and `22` today) and wrangler in each app repository's devDependencies plus lockfile; upgrade either through a reviewed change.
- Review lockfile diffs: dependency code runs during the build, the `wrangler secret bulk` step and the wrangler-action bundle step. The last two hold the deploy token.
- A person who can land code on the default branch can deploy the worker. Default-branch protection is the production authorization boundary. A person who can push a branch and open a pull request can deploy a preview only in the isolated preview account.

## Cloudflare controls

- Two accounts: production, which holds the zones and production workers, and preview, which holds only pull request workers. Never add a zone or a production resource to the preview account.
- One account-owned token per account, stored only in its matching `webops-shared-prod` config. The preview token has Workers-product `Admin`, so a leak compromises every preview Worker; rotate from one place.
- Keep the production token at Workers-product `Editor` in steady state. Add route permissions only for the production zones that need them. Use a separately controlled `Admin` credential to bootstrap a new production Worker.
- Remove unnecessary Cloudflare account memberships; deploys should flow through this workflow.

## Migration runbook

1. Put `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` in `webops-shared-prod` / `cloudflare-deploy-configs` for the production account and `webops-shared-prod` / `cloudflare-preview-deploy-configs` for the preview account.
2. Create the production service account and identity. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read only on `webops-shared-prod` / `cloudflare-deploy-configs` and `<project>` / `prd`.
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
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/cloudflare-deploy.yml`
- Sibling guide: `specs/doppler-vercel.md`
