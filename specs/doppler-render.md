# Render Deployment Operating Guide (Doppler)

- **Date:** 2026-11-01
- **Status:** Implemented in `yearn/yearn-gha`. Complete the migration runbook before you cut a service over.
- **Context:** Companion to `specs/doppler-vercel.md` and `specs/doppler-cloudflare.md`. Same threat model, same Doppler OIDC pattern, applied to Render services. It matches the reusable workflow in `.github/workflows/render-deploy.yml`. First caller: `yearn/kong`, background worker `ingest-v-2`.

## Decision

GitHub Actions authenticates to Doppler with OIDC, writes the service's runtime secrets to the Render env group that the service links, and triggers a Render deploy of the pushed commit through the Render API. Render clones and builds the commit on its own infrastructure. GitHub stores no long-lived credential.

**Production only — there are no previews.** The only supported trigger is a push to the caller repository's default branch. Every other event (`pull_request`, `workflow_dispatch`, `schedule`, non-default-branch pushes) is rejected before Doppler authentication (`.github/workflows/render-deploy.yml:56`).

**Render's own commit autodeploy is turned off for the service.** Today Render deploys `ingest-v-2` on every push to `main` through its GitHub app (`autoDeployTrigger: commit`). With this workflow, the push deploys through GitHub Actions instead. Two reasons:

1. Render redeploys a service on an env group change only when the service has autodeploy on. With autodeploy off, the secret write at `.github/workflows/render-deploy.yml:128` does not start a deploy of its own, and the one deploy per push comes from `.github/workflows/render-deploy.yml:156`.
2. A failed secret write fails the run before any deploy starts. With autodeploy on, Render would deploy the push whether or not the secrets landed.

The fleet uses one **shared Render API key**. Store `RENDER_API_KEY` once in `webops-shared-prod` / `render-deploy-configs` (`.github/workflows/render-deploy.yml:24-25`). Callers do not pass it.

**The Render config is separate from the Vercel and Cloudflare configs.** `dopplerhq/secrets-fetch-action` exports every value in the fetched config. One combined config would put every platform's credential on every platform's runner.

The guide distinguishes three kinds of data:

- **Deployment secret:** `RENDER_API_KEY`. Long-lived Render credential even though Doppler authentication is short-lived.
- **Deployment identifiers:** `RENDER_SERVICE_ID` (`srv-…`) and `RENDER_ENV_GROUP_ID` (`evg-…`). They select the targets; configuration, not authentication. They live in `<project>` / `deploy-configs` (`.github/workflows/render-deploy.yml:26`).
- **Application secrets:** RPC URLs, database credentials, API keys and similar values the service reads at runtime. They live in `<project>` / `prd` (`.github/workflows/render-deploy.yml:27`) and pass through the runner on every deploy.

## Application secrets: written by the workflow

Doppler has a managed Render sync, but it targets a service's own env vars, not an env group, and it does not redeploy on change. The fleet's Render services read an env group (`kong` for ingest), so the workflow writes the group directly.

The target is the env group's **secret file `.env`** (`.github/workflows/render-deploy.yml:30`), not the group's env vars. That matches how the service is wired today: the env group `kong` holds no env vars, only the secret file `.env`, and Render mounts a secret file at the service root for a non-Docker service. The ingest entrypoint loads `<repo-root>/.env` with dotenv (`packages/ingest/index.ts:15-16` in `yearn/kong`).

Three steps run after the shared fetch and `Validate Render credentials`:

1. **`Load service runtime secrets from Doppler`** (step `secrets`, `.github/workflows/render-deploy.yml:112`). `dopplerhq/secrets-fetch-action` v2.0.0 with `auth-method: oidc`, `doppler-project: ${{ inputs.project }}`, `doppler-config: prd`, and `inject-env-vars: false`. The values are step outputs, not job env.
2. **`Write runtime secrets to the Render env group secret file`** (`.github/workflows/render-deploy.yml:128`). A `run` step. It:
   - removes the Doppler meta keys `DOPPLER_PROJECT`, `DOPPLER_CONFIG`, `DOPPLER_ENVIRONMENT`;
   - fails with `::error::` if zero secrets remain. This catches a wrong `project` or an empty `prd` config;
   - fails if any value contains a single quote (`.github/workflows/render-deploy.yml:141`). See "Secret file format" below;
   - builds one `KEY='value'` line per secret, sorted by key, and sends it as the whole file content with `PUT /v1/env-groups/{id}/secret-files/.env`. The response body goes to `/dev/null`; it echoes the full env group.
3. **`Deploy to Render`** (`.github/workflows/render-deploy.yml:156`). `POST /v1/services/{id}/deploys` with `commitId: ${{ github.sha }}` (`.github/workflows/render-deploy.yml:164`), so Render deploys the pushed commit and not "latest on the branch". The step then polls the deploy every 15 s until a terminal status. `live` passes (`.github/workflows/render-deploy.yml:180`); `build_failed`, `update_failed`, `pre_deploy_failed`, `canceled`, and `deactivated` fail the run (`.github/workflows/render-deploy.yml:181`). The job timeout is 30 minutes (`.github/workflows/render-deploy.yml:37`).

### Secret file format

Each line is `KEY='value'`. dotenv (v16, used by kong) takes a single-quoted value verbatim: no `\n` expansion, no `$VAR` expansion, no `#` comment stripping, and a literal newline inside the quotes stays a newline. A value that itself contains `'` cannot be written in that form, so the workflow refuses it by key name and fails before any Render call. Store such a value differently (base64, or rotate it); do not relax the check. The format was verified against dotenv 16.4.7's parser with a multi-line value, a `"`, a `$VAR`, and a `#`.

Behaviour to know:

- **Full replace, not additive.** The whole file is rewritten on every deploy. A key removed from Doppler disappears from Render on the next deploy. This differs from the Cloudflare sync (`wrangler secret bulk` is additive).
- **Zero secrets is an error, not a no-op.** A `prd` config that resolves empty fails the deploy.
- **Secrets land before code.** The file is written, then the deploy starts. The running (old) instance does not re-read the file, so the window is the deploy itself: the new commit starts with the new file. Keep secret changes backward compatible across one deploy anyway, in case the deploy fails and the old commit is redeployed by hand against the new file.
- **One file per env group.** If two services share an env group, they share the file and both must read the same key set from one Doppler `prd`. Give each service its own env group if their secrets differ.
- **Masking.** The fetch action log-masks every value except values with Doppler visibility `Unmasked`. Set app secrets to Masked. The workflow never prints the file content; it prints the key count only.

## What this design protects—and what it does not

Provided controls:

- No static Doppler credential in GitHub; OIDC tokens are short-lived.
- The shared Render key is stored once, in one Doppler config, isolated from the Vercel and Cloudflare credentials.
- Runtime secrets have one source of truth (`<project>` / `prd`) and reach Render on every deploy, with no operator step and no drift: the file is replaced, not merged.
- **No repository code runs on the runner.** The job does no checkout and no install (`.github/workflows/render-deploy.yml:71` is the first step after the event gate). Render builds the commit. The only code that holds the Render key or the app secrets on the runner is the pinned fetch action, `jq`, and `curl`. This is a strictly smaller exposure than the Cloudflare workflow, where wrangler bundles the worker on the runner.
- Every value is read as a step output (`inject-env-vars: false`, `.github/workflows/render-deploy.yml:79,92,120`) and mapped explicitly into the steps that need it.
- The deploy of the pushed commit is followed to a terminal status, so a failed Render build fails the GitHub run.
- One trusted reusable workflow implements event checks, action pins, and validation. Callers pin it to a full commit SHA; Doppler identities bind `job_workflow_ref` to that SHA.

Not eliminated:

- `RENDER_API_KEY` is a long-lived credential on the runner. Render API keys are created in a user's Account Settings and are not scoped to a workspace or a service unless the workspace has Render's scoped API keys (early access at the time of writing). Compromise reaches every workspace that user can reach. Create the key from a dedicated deploy user with membership in the `yearn` workspace only.
- **App secrets land on the deploy runner** as step outputs of `secrets` and in one `run` step's env. A compromised GitHub-hosted runner, or a compromised fetch action release, can read them. Dependency code is not a vector here, because none runs.
- **Step ordering is not an authorization boundary.** `id-token: write` is job-scoped; any step in the job can mint the OIDC token and fetch from Doppler itself.
- **Render's GitHub connection stays.** Render still needs the repository connection to clone the commit. Turning autodeploy off stops Render's own push-triggered deploys; it does not stop a deploy started from the Render dashboard. A dashboard "Manual Deploy" of the latest commit bypasses this workflow and uses whatever `.env` the last run wrote.
- **A queued deploy may not be observed.** If Render answers `202` without a deploy id (a deploy already in progress from the dashboard), the step fails with the response body. The pushed commit may still deploy later through Render's queue. Re-run the job once the other deploy finishes.
- **Blueprint sync.** The caller's `render.yaml` is Blueprint-managed with autosync on. A `render.yaml` change still syncs through Render's GitHub connection, outside this workflow. Keep `autoDeploy: false` in `render.yaml`; a sync that re-enables it reintroduces double deploys.
- OIDC policy is an authorization boundary only when all relevant claims are checked; identity IDs are public metadata.

## Target architecture

- A small caller workflow in each service repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- The only supported trigger is a push to the caller repository's default branch. Everything else is rejected before Doppler authentication.
- The workflow fetches `RENDER_API_KEY` from `webops-shared-prod` / `render-deploy-configs`, fetches `RENDER_SERVICE_ID` and `RENDER_ENV_GROUP_ID` from `<project>` / `deploy-configs`, validates all three (including the `srv-` / `evg-` prefixes), fetches `<project>` / `prd`, writes the env group's `.env` secret file, triggers a deploy of `github.sha`, and waits for it.
- No checkout, no install, no path filter. Every push to the default branch deploys, which is parity with Render's commit autodeploy. For kong, `packages/lib` changes affect ingest, so a `packages/ingest/**` filter would be wrong.
- Post-deploy verification stays in the caller as a `needs:` job — the reusable workflow is deploy-only.
- Output: `deploy-id` — the Render deploy that went live.

### Caller shape

```yaml
name: Deploy ingest to Render

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write

cache-mode: none

jobs:
  ingest:
    uses: yearn/yearn-gha/.github/workflows/render-deploy.yml@<approved-sha> # full commit SHA only
    with:
      project: kong-ingest
      identity-id: ${{ vars.DOPPLER_RENDER_IDENTITY_ID }}
```

Repository variable: `DOPPLER_RENDER_IDENTITY_ID`. The Vercel and Cloudflare guides assume one platform per repository and both use `DOPPLER_PRODUCTION_IDENTITY_ID`. `yearn/kong` calls both `vercel-deploy.yml` (web) and `render-deploy.yml` (ingest), and each identity is bound to its own `job_workflow_ref`, so the Render identity needs its own variable name. Use `DOPPLER_RENDER_IDENTITY_ID` for every Render caller, including a repository with no Vercel deploy, so the name means one thing across the fleet. Identity IDs are not secrets.

Deploys are serialized by the reusable workflow itself (one job-level concurrency group per caller repository, `cancel-in-progress: false`, `.github/workflows/render-deploy.yml:42`). Callers need no concurrency block.

### Workflow inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `project` | yes | — | Doppler project holding the service's runtime secrets in `prd` and `RENDER_SERVICE_ID` + `RENDER_ENV_GROUP_ID` in `deploy-configs`. Every value in `prd` is written to the env group's `.env`. |
| `identity-id` | yes | — | Production Doppler service-account identity; used for all three fetches. |

Output: `deploy-id`.

### Rejected alternatives

- **Doppler's managed Render integration.** It syncs to a service's own env vars, not to an env group, and it does not redeploy on change. Service-level env vars override env group values, so it would have worked for kong by shadowing the group, but secret changes would land only on the next deploy, the sync is configured in the Doppler dashboard with a user's Render API key and no OIDC, and it leaves Render's commit autodeploy in place with no CI gate. It is still the right tool for a Render service with no CI and no env group.
- **Keep Render's commit autodeploy and only sync secrets from the workflow.** Double deploys on every push (one from Render's webhook, one from the env group change), and no way to fail the push when the secret write fails.
- **Write env group env vars instead of the secret file.** `PUT /v1/env-groups/{id}` replaces the whole group, secret files included, which is a bigger blast radius than one file; the per-key `PUT /v1/env-groups/{id}/env-vars/{key}` is additive and keeps stale keys. The service already reads `.env`, so the file is the smaller change and the only non-additive option.
- **Write the service's own env vars.** `PUT /v1/services/{id}/env-vars` is a full replace and would delete the two `fromService` Redis links that `render.yaml` declares on the service. The env group is the right owner for runtime secrets.
- **Doppler CLI with an OIDC token exchange instead of the fetch action.** `doppler secrets download --format env` quotes values itself, so the single-quote restriction would go away. It adds a token exchange and a CLI install to the job for one edge case. Revisit if a real secret needs a `'`.
- **`workflow_dispatch` manual deploys.** Same rationale as the other guides: broadens deployment authority and bypasses the event gate. Render's dashboard "Manual Deploy" already exists for emergencies, and the risk section names it.
- **Path filter on `packages/ingest/**`.** Shared packages (`packages/lib`) change ingest behaviour. Parity with today's commit autodeploy is "every push".

## Doppler configuration

Service Account Identities require a Doppler Team or Enterprise workplace.

### Shared deployment project

In the existing `webops-shared-prod` Doppler project, config `render-deploy-configs` (created 2026-11-01, empty until the key is added):

- `RENDER_API_KEY`: shared Render API key. Create it from a dedicated deploy user whose only workspace is `yearn`. Set Doppler visibility to **Masked** — the fetch action registers GitHub log redaction only for values that are not Unmasked.

Keep only that value in the config: every value in it is fetched onto the runner as a step output.

### Application project

One Doppler project per Render service, passed as the `project` input. Two environments, each with one config of the same slug:

| Environment | Config | Contents | Consumer |
| ----------- | ------ | -------- | -------- |
| Production | `prd` | Runtime secrets, every one written to the env group's `.env` | GitHub Actions → Render env group |
| deploy-configs | `deploy-configs` | `RENDER_SERVICE_ID`, `RENDER_ENV_GROUP_ID` only | GitHub Actions |

For kong: project `kong-ingest` (created 2026-11-01). `prd` was seeded from the live `kong` env group `.env` secret file and verified equal key-for-key and value-for-value (61 keys). `deploy-configs` holds `RENDER_SERVICE_ID=srv-d3dks2b7mgec73cv369g` (`ingest-v-2`) and `RENDER_ENV_GROUP_ID=evg-d3dkc7jipnbc73ce23lg` (`kong`). The existing `kong-api` project stays the web app's: its `prd` holds `NEXT_PUBLIC_*`, `TURBO_*` and the GraphQL cache Redis URLs, none of which ingest reads, and a branch config off it would inherit them into the file.

Set each `prd` value to Masked. The deploy identity gets read access to both configs.

### Service accounts, identities, and OIDC

Create one production Doppler service-account identity per Render caller repository. Grant the underlying service account read-only access to exactly three configs: `webops-shared-prod` / `render-deploy-configs`, `<project>` / `deploy-configs`, and `<project>` / `prd`.

The identity uses:

- Provider: GitHub (`https://token.actions.githubusercontent.com`)
- Audience matching the action's token (verify against a real token; usually `https://github.com/<org>`)
- Subject: `repo:<org>/<repo>:ref:refs/heads/<default-branch>` (or the immutable-format equivalent)
- Exact additional claims: `event_name=push`, `ref=refs/heads/<default-branch>`, and `job_workflow_ref=yearn/yearn-gha/.github/workflows/render-deploy.yml@<approved-sha>`
- No wildcards on claims.

The `job_workflow_ref` condition is mandatory — without it, any workflow in the repository with `id-token: write` can request the identity. Bind it to the same full commit SHA callers pin in `uses:`; update caller pins and identity claims together in a reviewed rollout. The subject and `ref` bindings are defense in depth on top of the workflow's own default-branch check.

For kong this is a **second** production identity, separate from the one bound to `vercel-deploy.yml`. Do not add `render-deploy-configs` or `kong-ingest` grants to the Vercel identity.

## GitHub controls

Same as the Vercel guide (`specs/doppler-vercel.md` — branch protection, no `pull_request_target`, SHA-pinned actions). Render-specific additions:

- The reusable workflow owns deploy serialization: one job-level concurrency group per caller repository, `cancel-in-progress: false`. A cancelled job does not cancel the Render deploy it started; it only loses the status check.
- The job has no checkout, so there is no lockfile and no dependency code to review for this path.
- A person who can land code on the default branch can deploy the service. Default-branch protection is the production authorization boundary — there is no other deploy path through this workflow.

## Render controls

- One API key for the fleet, stored only in `webops-shared-prod` / `render-deploy-configs`. Rotate from one place. Prefer a scoped key limited to the `yearn` workspace once Render's scoped keys are generally available.
- `autoDeploy: false` on every service this workflow deploys, declared in the caller's `render.yaml` so a Blueprint sync cannot turn it back on.
- Keep the env group linked to one service unless the services share one `prd` on purpose.
- Remove unnecessary Render workspace memberships; deploys should flow through this workflow.

## Migration runbook

Steps 1 and 4 are done for kong (2026-11-01). The rest need the Doppler and Render dashboards or a reviewed PR.

1. Create `webops-shared-prod` / `render-deploy-configs`. Create `<project>` with `prd` and `deploy-configs`; seed `prd` from the live env group file and diff keys and values before the first run; set `RENDER_SERVICE_ID` and `RENDER_ENV_GROUP_ID` in `deploy-configs`.
2. Create a dedicated Render deploy user in the `yearn` workspace, create its API key, and put it in `render-deploy-configs` as `RENDER_API_KEY` (Masked).
3. Create the production Doppler identity. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read on the three configs above. Set its ID as the `DOPPLER_RENDER_IDENTITY_ID` repository variable.
4. Add the caller workflow with the pinned reusable SHA.
5. Merge the caller. The first run writes the same `.env` Render already has and deploys the merge commit. Render's commit autodeploy also fires on that push, so expect two deploys for this one merge; the later one wins.
6. After the first green run, set `autoDeploy: false` on the service in `render.yaml` and merge. From then on every push deploys once, through the workflow.
7. Confirm a pull request run fails at the event check without touching Doppler, and that a later push to `main` deploys exactly once.
8. Retire the dashboard `.env` as a place operators edit. Doppler `prd` is the source of truth; the next deploy overwrites the file.

## References

- [Doppler service account identities (OIDC)](https://docs.doppler.com/docs/service-account-identities)
- [Doppler Secrets Fetch Action](https://github.com/DopplerHQ/secrets-fetch-action)
- [Doppler Render integration (managed sync, not used)](https://docs.doppler.com/docs/render)
- [Render API: update env group secret file](https://api-docs.render.com/reference/update-env-group-secret-file)
- [Render API: trigger a deploy](https://api-docs.render.com/reference/create-deploy)
- [Render: environment groups and secret files](https://render.com/docs/configure-environment-variables)
- [Render API keys](https://render.com/docs/api)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/render-deploy.yml`
- Sibling guides: `specs/doppler-vercel.md`, `specs/doppler-cloudflare.md`
