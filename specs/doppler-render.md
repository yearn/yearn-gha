# Render Deployment Operating Guide (Doppler)

- **Date:** 2026-11-01
- **Status:** Implemented in `yearn/yearn-gha`. Complete the migration runbook before you cut a service over.
- **Context:** Companion to `specs/doppler-vercel.md` and `specs/doppler-cloudflare.md`. Same threat model, same Doppler OIDC pattern, applied to Render services. It matches the reusable workflow in `.github/workflows/render-deploy.yml`. First caller: `yearn/kong`, background worker `ingest-v-2`.

## Decision

GitHub Actions authenticates to Doppler with OIDC and triggers a Render deploy of the pushed commit through the Render API. Render clones and builds the commit on its own infrastructure. GitHub stores no long-lived credential.

**Runtime secrets are not this workflow's job.** Doppler's Render sync integration pushes `<project>` / `prd` to the service. The workflow never fetches `prd`.

**Production only — there are no previews.** The only supported trigger is a push to the caller repository's default branch. Every other event (`pull_request`, `workflow_dispatch`, `schedule`, non-default-branch pushes) is rejected before Doppler authentication (`.github/workflows/render-deploy.yml:52`).

**Render's own commit autodeploy is turned off for the service.** Today Render deploys `ingest-v-2` on every push to `main` through its GitHub app (`autoDeployTrigger: commit`). With autodeploy on, every push would deploy twice. The one deploy per push comes from `.github/workflows/render-deploy.yml:108`.

The fleet uses one **shared Render API key**. Store `RENDER_API_KEY` once in `webops-shared-prod` / `render-deploy-configs` (`.github/workflows/render-deploy.yml:24-25`). Callers do not pass it.

**The Render config is separate from the Vercel and Cloudflare configs.** `dopplerhq/secrets-fetch-action` exports every value in the fetched config. One combined config would put every platform's credential on every platform's runner.

The guide distinguishes three kinds of data:

- **Deployment secret:** `RENDER_API_KEY`. Long-lived Render credential even though Doppler authentication is short-lived.
- **Deployment identifier:** `RENDER_SERVICE_ID` (`srv-…`). Configuration, not authentication. It lives in `<project>` / `deploy-configs` (`.github/workflows/render-deploy.yml:26`).
- **Application secrets:** values the service reads at runtime. They live in `<project>` / `prd` and reach Render through the Doppler Render sync. They never touch the runner.

## Deploy step

`Deploy to Render` (`.github/workflows/render-deploy.yml:108`) sends `POST /v1/services/{id}/deploys` with `commitId: ${{ github.sha }}` (`.github/workflows/render-deploy.yml:116`), so Render deploys the pushed commit and not "latest on the branch". The step polls the deploy every 15 s until a terminal status. `live` passes (`.github/workflows/render-deploy.yml:132`); `build_failed`, `update_failed`, `pre_deploy_failed`, `canceled`, and `deactivated` fail the run (`.github/workflows/render-deploy.yml:133`). The job timeout is 30 minutes (`.github/workflows/render-deploy.yml:33`).

## What this design protects—and what it does not

Provided controls:

- No static Doppler credential in GitHub; OIDC tokens are short-lived.
- The shared Render key is stored once, in one Doppler config, isolated from the Vercel and Cloudflare credentials.
- Runtime secrets have one source of truth (`<project>` / `prd`) and never pass through the runner.
- **No repository code runs on the runner.** The job does no checkout and no install (`.github/workflows/render-deploy.yml:67` is the first step after the event gate). Render builds the commit. The only code that holds the Render key on the runner is the pinned fetch action, `jq`, and `curl`. This is a strictly smaller exposure than the Cloudflare workflow, where wrangler bundles the worker on the runner.
- Every value is read as a step output (`inject-env-vars: false`, `.github/workflows/render-deploy.yml:75,87`) and mapped explicitly into the steps that need it.
- The deploy of the pushed commit is followed to a terminal status, so a failed Render build fails the GitHub run.
- One trusted reusable workflow implements event checks, action pins, and validation. Callers pin it to a full commit SHA; Doppler identities bind `job_workflow_ref` to that SHA.

Not eliminated:

- `RENDER_API_KEY` is a long-lived credential on the runner. Render API keys are created in a user's Account Settings and are not scoped to a workspace or a service unless the workspace has Render's scoped API keys (early access at the time of writing). Compromise reaches every workspace that user can reach. Create the key from a dedicated deploy user with membership in the `yearn` workspace only.
- **Secret sync is decoupled from deploys.** The Doppler Render sync is configured in the Doppler dashboard with a Render API key, outside OIDC. A `prd` change does not redeploy by itself (autodeploy is off); it takes effect on the next deploy. Keep secret changes backward compatible across one deploy.
- **Step ordering is not an authorization boundary.** `id-token: write` is job-scoped; any step in the job can mint the OIDC token and fetch from Doppler itself.
- **Render's GitHub connection stays.** Render still needs the repository connection to clone the commit. Turning autodeploy off stops Render's own push-triggered deploys; it does not stop a deploy started from the Render dashboard. A dashboard "Manual Deploy" of the latest commit bypasses this workflow.
- **A queued deploy may not be observed.** If Render answers `202` without a deploy id (a deploy already in progress from the dashboard), the step fails with the response body. The pushed commit may still deploy later through Render's queue. Re-run the job once the other deploy finishes.
- **Blueprint sync.** The caller's `render.yaml` is Blueprint-managed with autosync on. A `render.yaml` change still syncs through Render's GitHub connection, outside this workflow. Keep `autoDeploy: false` in `render.yaml`; a sync that re-enables it reintroduces double deploys.
- OIDC policy is an authorization boundary only when all relevant claims are checked; identity IDs are public metadata.

## Target architecture

- A small caller workflow in each service repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- The only supported trigger is a push to the caller repository's default branch. Everything else is rejected before Doppler authentication.
- The workflow fetches `RENDER_API_KEY` from `webops-shared-prod` / `render-deploy-configs`, fetches `RENDER_SERVICE_ID` from `<project>` / `deploy-configs`, validates both (including the `srv-` prefix), triggers a deploy of `github.sha`, and waits for it.
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

Deploys are serialized by the reusable workflow itself (one job-level concurrency group per caller repository, `cancel-in-progress: false`, `.github/workflows/render-deploy.yml:38`). Callers need no concurrency block.

### Workflow inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `project` | yes | — | Doppler project holding `RENDER_SERVICE_ID` in `deploy-configs`. |
| `identity-id` | yes | — | Production Doppler service-account identity; used for both fetches. |

Output: `deploy-id`.

### Rejected alternatives

- **Write runtime secrets from the workflow** (env group secret file via the Render API). Doppler's Render sync already does this; doing it in CI would put every app secret on the runner and duplicate the integration.
- **Keep Render's commit autodeploy.** Double deploys on every push, and no CI gate on the deploy.
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
| Production | `prd` | Runtime secrets | Doppler Render sync → Render service |
| deploy-configs | `deploy-configs` | `RENDER_SERVICE_ID` only | GitHub Actions |

For kong: project `kong-ingest` (created 2026-11-01). `deploy-configs` holds `RENDER_SERVICE_ID=srv-d3dks2b7mgec73cv369g` (`ingest-v-2`). Connect `prd` to `ingest-v-2` with the Doppler Render sync.

The deploy identity gets read access to `deploy-configs` only, not `prd`.

### Service accounts, identities, and OIDC

Create one production Doppler service-account identity per Render caller repository. Grant the underlying service account read-only access to exactly two configs: `webops-shared-prod` / `render-deploy-configs` and `<project>` / `deploy-configs`.

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
- Remove unnecessary Render workspace memberships; deploys should flow through this workflow.

## Migration runbook

Steps need the Doppler and Render dashboards or a reviewed PR.

1. Create `webops-shared-prod` / `render-deploy-configs`. Create `<project>` with `prd` and `deploy-configs`; set `RENDER_SERVICE_ID` in `deploy-configs`.
2. Connect `<project>` / `prd` to the service with the Doppler Render sync integration.
3. Create a dedicated Render deploy user in the `yearn` workspace, create its API key, and put it in `render-deploy-configs` as `RENDER_API_KEY` (Masked).
4. Create the production Doppler identity. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read on the two configs above. Set its ID as the `DOPPLER_RENDER_IDENTITY_ID` repository variable.
5. Add the caller workflow with the pinned reusable SHA and merge. Render's commit autodeploy also fires on that push, so expect two deploys for this one merge.
6. After the first green run, set `autoDeploy: false` on the service in `render.yaml` and merge.
7. Confirm a pull request run fails at the event check without touching Doppler, and that a later push to `main` deploys exactly once.

## References

- [Doppler service account identities (OIDC)](https://docs.doppler.com/docs/service-account-identities)
- [Doppler Secrets Fetch Action](https://github.com/DopplerHQ/secrets-fetch-action)
- [Doppler Render integration](https://docs.doppler.com/docs/render)
- [Render API: trigger a deploy](https://api-docs.render.com/reference/create-deploy)
- [Render API keys](https://render.com/docs/api)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/render-deploy.yml`
- Sibling guides: `specs/doppler-vercel.md`, `specs/doppler-cloudflare.md`
