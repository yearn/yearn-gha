# Vercel Deployment Operating Guide (Doppler)

- **Date:** 2026-08-12
- **Status:** Implemented in `yearn/yearn-gha`. Complete the per-app migration runbook before cutting a project over.
- **Context:** This guide follows the TanStack npm supply-chain compromise of May 2026 and replaces the Infisical design. It matches the reusable workflow in `.github/workflows/vercel-deploy.yml`.

## Decision

GitHub Actions initiates Vercel deployments. GitHub Actions authenticates to Doppler with OIDC, so GitHub stores no long-lived Doppler credential. Doppler Vercel integrations send application secrets directly to Vercel; application secrets are not loaded onto the GitHub runner.

The fleet uses one **shared team-scoped Vercel access token**. There is no per-project token. Store `VERCEL_TOKEN` and `VERCEL_ORG_ID` once in `webops-shared-prod` / `deploy-configs`; each application project stores only its own `VERCEL_PROJECT_ID`. The reusable workflow hardcodes `SHARED_PROJECT: webops-shared-prod` and `DEPLOY_CONFIG: deploy-configs` (`.github/workflows/vercel-deploy.yml:22-24`) — callers do not pass them. A leaked token can reach every Vercel project the team token can access.

The guide distinguishes three kinds of data:

- **Deployment secret:** `VERCEL_TOKEN`. This is a long-lived Vercel credential even though Doppler authentication is short-lived.
- **Deployment identifiers:** `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID`. These select the Vercel team and project; they are configuration identifiers, not authentication credentials.
- **Application secrets:** database URLs, RPC credentials, API tokens, signing keys, and similar values used by the application.

Keep deployment data in a sibling Doppler environment/config named `deploy-configs`. Keep application secrets in `prd` (Production) and `preview`. Never put application secrets in `deploy-configs` because `dopplerhq/secrets-fetch-action` with `inject-env-vars: true` exports every value in that config to the GitHub runner (`.github/workflows/vercel-deploy.yml:66-90`).

Doppler has no Infisical-style folder-in-env. Isolation is a separate config, not a path under `prd` or `preview`.

## Implementation status (yearn-gha)

The reusable workflow already implements the core design:

| Control | Status |
| ------- | ------ |
| OIDC login to Doppler (no static Doppler token in GitHub) | Done |
| Shared `webops-shared-prod` for `VERCEL_TOKEN` + `VERCEL_ORG_ID` | Done (hardcoded project + `deploy-configs`) |
| App project supplies only `VERCEL_PROJECT_ID` in `deploy-configs` | Done (hardcoded config slug) |
| Event-derived preview vs production (no caller `--prod` / environment input) | Done |
| Reject fork PRs before Doppler auth | Done |
| Reject `workflow_dispatch`, `schedule`, and non-default-branch pushes before Doppler auth | Done |
| Validate `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` before deploy | Done |
| SHA-pinned third-party actions + Vercel CLI `55.0.0` | Done |
| Caller examples pin reusable workflow to full commit SHA | Done (examples use the `@<approved-sha>` placeholder; replace at rollout) |
| Exact `job_workflow_ref` on Doppler OIDC identities | Documented; configure per identity at rollout |
| `split-app-env` / event-specific deploy-config fetch | **Rejected.** One `deploy-configs` for preview and production. |

Remaining work is **operational**: Doppler projects/identities/Vercel integrations per app, repository variables, coordinated SHA pin + claim updates, branch protection, and cutover.

## What this design protects—and what it does not

The TanStack incident combined a `pull_request_target` “pwn request,” cache poisoning across the fork/base trust boundary, and runtime extraction of an OIDC token from runner memory. A moved action tag was not the exploit chain, although floating action references are a separate supply-chain risk.

This design provides the following controls:

- GitHub stores no static Doppler service-account token. The GitHub OIDC token and the Doppler access token obtained from it are short-lived.
- Application secrets do not pass through GitHub Actions. They move from Doppler to Vercel through the Vercel integration (`prd` → Production, `preview` → Preview).
- Of the deployment data described here, the GitHub runner receives only `VERCEL_TOKEN` and the two Vercel identifiers.
- The shared Vercel token and organization ID are stored once in Doppler rather than copied into every application project.
- A trusted reusable workflow provides one implementation of event checks, action pins, CLI pins, and validation.
- Callers pin the reusable workflow to a full commit SHA; Doppler identities should bind `job_workflow_ref` to that same SHA so a PR cannot swap the caller for an arbitrary workflow that authenticates to Doppler.

This design does **not** eliminate these risks:

- `VERCEL_TOKEN` is still a long-lived credential exposed to the deployment action and Vercel CLI on the GitHub runner. OIDC removes the static **Doppler** credential; it does not make the Vercel token ephemeral.
- Because the Vercel token is one team token, its compromise is a fleet-wide incident. Do not copy it outside `webops-shared-prod` / `deploy-configs`.
- Preview application secrets are available to the Vercel build. Code in a same-repository pull request can try to exfiltrate them during its build. The initial preview and production configs may contain the same non-sensitive, revocable values, but preview must never receive customer data, privileged credentials, or a value that cannot safely be rotated. The Vercel “sensitive” flag hides values in management surfaces; it does not make them unavailable to application or build code.
- A compromised approved central-workflow SHA can affect callers that have been deliberately updated to it. Full-SHA caller pins prevent a later change to a branch or tag from silently changing deployed workflow code.
- GitHub is the automated deployment gate, but Vercel still authorizes the access token and existing Vercel members may be able to deploy manually. Remove unnecessary Vercel memberships and use the narrowest Vercel roles available.
- OIDC policy is an authorization boundary only when all relevant claims are checked. The identity ID itself is public metadata and provides no security.
- **`deploy-configs` residual risk:** preview and production runs both read the same app `deploy-configs` (and the same shared `deploy-configs`). Those configs must hold only the intended deploy values. Anything later added there is exported to the runner. Do not grant the deploy identities access to `prd` or `preview`.

## Target architecture

- Vercel’s Git integration is disconnected after migration to avoid duplicate deployments.
- A small caller workflow in each application repository invokes the SHA-pinned reusable workflow in `yearn/yearn-gha`.
- The trigger determines the deployment type. Callers do not choose it:
  - A same-repository `pull_request` creates a Vercel Preview deployment and uses application secrets synced from Doppler `preview`.
  - A push to the caller repository’s default branch creates a Production deployment with `--prod` and uses application secrets synced from Doppler `prd`.
  - Fork pull requests, `pull_request_target`, `workflow_dispatch`, schedules, and pushes to other branches are rejected before Doppler authentication. `workflow_dispatch` is intentionally disabled in the initial design because it broadens deployment authority and can bypass the normal event gate. Add a separately reviewed, approval-gated manual path only if an operational need emerges.
- The reusable workflow fetches the token and organization ID from `webops-shared-prod` / `deploy-configs`, then fetches the project ID from the application project’s `deploy-configs`. It never loads `prd` or `preview`.
- The same Doppler service-account identity authenticates both the shared and app fetches. Callers pass one event-appropriate `identity-id` (preview or production).
- The reusable workflow runs `vercel deploy`; the build happens on Vercel with the environment variables already delivered by the Doppler Vercel integration.

GitHub becomes the primary human gate for automated deployments. Vercel remains an authorization boundary for the shared team token and for people who retain Vercel access.

### Why not per-env deploy-config

Infisical isolated deploy creds as a folder (`/deploy-config`) inside each env, and offered `split-app-env` to read `dev` vs `prod`. Doppler isolation is a whole config. The workflow therefore always reads `deploy-configs` for both shared and app fetches.

Rejected alternatives:

- **Fetch `prd` / `preview` from GHA.** Those configs sync to Vercel and hold application secrets. The action would dump them onto the runner.
- **Put `deploy-configs` inside each env as a second config named `prd`/`preview`.** Name collision with the synced app configs; preview identity would then need those names.
- **`split-app-env`.** Only useful if preview and production needed different `VERCEL_PROJECT_ID` values. Current fleet uses one Vercel project per app. Re-introduce only if that changes, via two dedicated deploy configs — never via `prd`/`preview`.
- **Shared fetch per preview/prd.** `VERCEL_TOKEN` and `VERCEL_ORG_ID` are environment-agnostic. Shared stay in `webops-shared-prod` / `deploy-configs`.

### Caller shape

```yaml
name: Deploy to Vercel

on:
  pull_request:
  push:
    branches: [main] # or master — match the repository default branch

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
    uses: yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha> # full commit SHA only
    with:
      project: my-app
      identity-id: ${{ github.event_name == 'pull_request' && vars.DOPPLER_PREVIEW_IDENTITY_ID || vars.DOPPLER_PRODUCTION_IDENTITY_ID }}
```

Repository variables: `DOPPLER_PREVIEW_IDENTITY_ID`, `DOPPLER_PRODUCTION_IDENTITY_ID`. Identity IDs are not secrets.

### Workflow inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `project` | yes | — | Doppler project that holds the app’s `VERCEL_PROJECT_ID` in `deploy-configs`. |
| `identity-id` | yes | — | Event-matching Doppler service-account identity; used for both shared and app `deploy-configs` fetches. |

Output: `deployment-url` (preview or production URL from Vercel).

## Doppler configuration

Service Account Identities require a Doppler Team or Enterprise workplace.

### Shared deployment project

Create or retain the `webops-shared-prod` Doppler project:

- Environment / config `deploy-configs`
  - `VERCEL_TOKEN`: the shared team-scoped Vercel token used by every application deployment. Set its Doppler visibility to **Masked**. The fetch action registers GitHub log redaction only for values that are not Unmasked. An Unmasked token shows in plaintext if it reaches a log.
  - `VERCEL_ORG_ID`

Keep the shared token only in this project and config. Do not copy it into application projects. Grant each application’s preview and production identities read access only to this exact project and config.

Do not attach a Vercel integration to `webops-shared-prod`.

### Application project

Create one Doppler project per application with three environments, each with one config of the same slug:

| Environment | Config | Contents | Consumer |
| ----------- | ------ | -------- | -------- |
| Production | `prd` | Application secrets | Doppler → Vercel Production |
| preview | `preview` | Preview-safe application secrets | Doppler → Vercel Preview |
| deploy-configs | `deploy-configs` | `VERCEL_PROJECT_ID` only | GitHub Actions |

`prd` and `preview` may initially share the same non-sensitive, revocable values. Preview must never receive customer data, privileged credentials, or a value that cannot safely be rotated.

If multiple applications share an application secret, manage it through an explicit Doppler workplace sharing mechanism supported by the plan. Do not place shared application secrets in `deploy-configs` and do not create unmanaged copies.

### Vercel integrations

Create two integrations per application (Doppler requires a separate Vercel integration per Vercel environment):

- Doppler `preview` → Vercel Preview.
- Doppler `prd` → Vercel Production.

Do not create an integration from `deploy-configs` to any Vercel environment. That is what keeps deploy credentials out of the app env.

Doppler defaults new Vercel syncs to Sensitive. If an existing sync predates that default, delete and recreate it with Sensitive selected; choose deletion of the Vercel copies when prompted so old Encrypted values do not remain.

A third integration (`dev` → Vercel Development) is optional for local `vercel env pull`. It is not part of this workflow.

### Service accounts, identities, and OIDC

Create two Doppler service-account identities per application repository: preview and production. Give the underlying service account read-only access only to:

- `webops-shared-prod` / `deploy-configs`
- the application project / `deploy-configs`

Do not grant the deploy service account access to `prd` or `preview`.

The official fetch action authenticates with `core.getIDToken()` and no custom audience (`.github/workflows/vercel-deploy.yml:71-78`). Configure each identity so audience and subject match the token GitHub actually issues. Confirm against a real token from a test run; do not assume a Doppler UI preset without checking. GitHub’s default audience is typically `https://github.com/<org>`.

Both identities use:

- Provider: GitHub (`https://token.actions.githubusercontent.com`)
- Audience matching the action’s token (verify; usually `https://github.com/<org>`)
- Exact additional claim: `job_workflow_ref=yearn/yearn-gha/.github/workflows/vercel-deploy.yml@<approved-sha>`
- Avoid wildcards on claims.

The `job_workflow_ref` condition is mandatory. Without it, any workflow in the repository with `id-token: write` can request the identity. Bind the claim to the same full commit SHA that callers pin in `uses:`. Update caller pins and identity claims together in a reviewed rollout. Do not use a moving branch or tag reference for the reusable workflow.

Add event-specific conditions:

- **Preview identity**
  - Subject (older GitHub format): `repo:<org>/<repo>:pull_request`
  - Subject (immutable format): `repo:<org>@<owner-id>/<repo>@<repo-id>:pull_request`
  - Additional claim: `event_name=pull_request`
- **Production identity**
  - Older subject: `repo:<org>/<repo>:ref:refs/heads/<default-branch>`
  - Immutable subject: `repo:<org>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/<default-branch>`
  - Additional claims: `event_name=push` and `ref=refs/heads/<default-branch>`

Access grants:

| Identity | Shared project | App project |
| -------- | -------------- | ----------- |
| Preview (`pull_request`) | `webops-shared-prod` / `deploy-configs` | `<app>` / `deploy-configs` |
| Production (`push`) | `webops-shared-prod` / `deploy-configs` | `<app>` / `deploy-configs` |

The production identity’s OIDC subject binding (`ref:refs/heads/<default-branch>`) is defense in depth on top of the workflow’s own default-branch check (`.github/workflows/vercel-deploy.yml:52-61`).

Identity IDs are not secrets and may be stored as repository variables or committed. The configured subject, audience, claims, and service-account project/config role are the authorization controls. The same identity authenticates both the shared and app fetches — do not introduce a separate shared-only identity unless the design is deliberately revised.

## GitHub controls

### Branch and workflow protection

- Protect the default branch of every application repository and `yearn/yearn-gha` with the rulesets or branch protection supported by the organization’s GitHub plan.
- Require pull requests, required status checks, and at least one approval. Require additional approval for `yearn/yearn-gha` because it is deployment infrastructure.
- Add CODEOWNERS coverage for `.github/workflows/**` in callers and the reusable workflow in `yearn/yearn-gha`.
- Disable administrator/ruleset bypass where the plan permits it. If bypass cannot be disabled, document it as a residual risk.
- GitHub Free does not provide branch protection for private repositories. Before migrating a private repository, confirm that it has a plan and ruleset/branch-protection capability that meet these controls; otherwise treat that as a rollout blocker.

A person who can land code on the production branch can cause a production deployment. That makes default-branch protection part of the production authorization boundary.

### Workflow safety

- Pin every third-party action to a full commit SHA. Human-readable version comments are informational only. Current pins in the reusable workflow: `actions/checkout`, `dopplerhq/secrets-fetch-action` (`v2.0.0` / `451892f…`), `amondnet/vercel-action`.
- Pin the Vercel CLI to an exact reviewed version. The current repository uses `55.0.0`; upgrade it through a reviewed change.
- Pin the reusable workflow to a full commit SHA. Update callers and their Doppler `job_workflow_ref` conditions together in a reviewed rollout.
- The caller grants only the permissions required by enabled features: `contents: read`, `id-token: write`, and — while deployment records and PR comments are enabled — `deployments: write` and `pull-requests: write`.
- Do not use `pull_request_target` for deployments.
- Reject unsupported events and fork PRs before checkout or Doppler authentication. The workflow enforces this itself rather than depending on GitHub’s current fork-token behavior.
- Derive preview versus production inside the reusable workflow (`DEPLOY_ENV` from `github.event_name`). Do not accept a caller-controlled `--prod` flag or deployment environment.
- Keep `workflow_dispatch` disabled unless a separately reviewed manual-deployment design adds default-branch restriction, an approval gate, and matching OIDC conditions.
- Validate that all three Vercel values are present before invoking the deployment action.
- Use concurrency with cancellation so a newer commit supersedes an obsolete deployment for the same PR or branch.

If production uses a GitHub Environment with required reviewers, update the OIDC policy deliberately: referencing an environment changes GitHub’s default OIDC subject to `repo:<org>/<repo>:environment:<name>` (or the immutable equivalent). Preserve explicit `event_name`, `ref`, and `job_workflow_ref` conditions.

## Vercel controls

- One team-scoped Vercel token for the whole fleet. There is no per-project token. Store it (with `VERCEL_ORG_ID`) only in `webops-shared-prod` / `deploy-configs`. A leak is fleet-wide.
- Disconnect the Vercel Git integration after this workflow has deployed successfully, so a push does not create two deployments.
- A new Vercel project’s first deployment is always Production, even without `--prod`.

## Migration runbook

1. Put `VERCEL_TOKEN` and `VERCEL_ORG_ID` in `webops-shared-prod` / `deploy-configs`. Put `VERCEL_PROJECT_ID` in the app project’s `deploy-configs`.
2. Create preview and production Doppler identities. Bind subject, audience, `event_name`, `ref`, and `job_workflow_ref` to the pinned workflow SHA. Grant read only on shared + app `deploy-configs`.
3. Sync Doppler `preview` → Vercel Preview and `prd` → Vercel Production. Do not attach `deploy-configs`. Re-enter any empty sensitive values; Vercel does not export them.
4. Add the caller workflow, pin the reusable SHA, set `DOPPLER_*_IDENTITY_ID` vars, and match the identity claims to that SHA.
5. Confirm a same-repo PR deploys preview. Then disconnect the Vercel Git integration so only this workflow deploys.

## References

- [TanStack incident postmortem](https://tanstack.com/blog/npm-supply-chain-compromise-postmortem)
- [GitHub OIDC reference, including immutable subjects](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub OIDC with reusable workflows](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-with-reusable-workflows)
- [Doppler service account identities (OIDC)](https://docs.doppler.com/docs/service-account-identities)
- [Doppler GitHub OIDC examples](https://docs.doppler.com/docs/github-oidc-examples)
- [Doppler Secrets Fetch Action](https://github.com/DopplerHQ/secrets-fetch-action)
- [Doppler Vercel integration](https://docs.doppler.com/docs/vercel)
- [Vercel access-token scopes](https://vercel.com/docs/accounts/access-tokens)
- [Vercel CLI token management](https://vercel.com/docs/cli/tokens)
- [Vercel deployment environments](https://vercel.com/docs/deployments/environments)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/vercel-deploy.yml`
- Harness: `yearn/yearn-practice-dummy` — `.github/workflows/vercel-deploy.yml` pinned to this branch’s SHA
