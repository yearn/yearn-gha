# Cloudflare Deployment Operating Guide

- **Date:** 2026-07-15
- **Home:** this file in `yearn/yearn-gha` (`docs/cloudflare-deployment-operating-guide.md`) is the operating guide for the Cloudflare Workers reusable workflow. Prefer editing here over ad-hoc HackMD copies.
- **Context:** Parallel to the [Vercel Deployment Operating Guide](https://hackmd.io/@murderteeth/B1aFfRIXMx); companion to `yearn/yearn-gha` Cloudflare reusable workflow (`.github/workflows/cloudflare-deploy.yml`) under the same post–TanStack (May 2026) guardrails.
- **Scope:** Cloudflare **Workers** (Wrangler). Cloudflare Pages, Workers Builds product details beyond “turn vendor auto-deploy off,” Durable Objects–specific secret models, and Workers for Platforms are out of scope unless explicitly extended later.

## What we do today

- Worker projects deploy through a mix of paths: local `wrangler deploy`, ad-hoc GitHub Actions, Cloudflare dashboard deploys, Workers Builds / Git integration, or other IaC. Deploy credentials and Worker secrets often live in **GitHub Actions secrets**, the **Cloudflare dashboard**, or both.
- Permissions are split across two systems: **GitHub** controls who can change the code, **Cloudflare** controls who can deploy Workers and who can read or edit dashboard secrets / API tokens.
- API tokens and account access are easy to over-scope. A shared token with broad Workers permissions, or secrets entered only in the Cloudflare UI, makes rotation and audit uneven across projects.

## What we're moving to

1Password becomes the **source of truth for editing and rotating deploy secrets**. Per project:

- A GitHub Actions deploy workflow (push to `main`) loads secrets from 1Password via `1password/load-secrets-action`, uploads declared Worker secrets with `wrangler secret bulk`, then deploys with the project’s own `bun run deploy` (Wrangler under the hood).
- The deploy workflow is defined **once**, as a reusable workflow (`workflow_call`) in a central repo (`yearn/yearn-gha`, which must be **public** so branch protection is enforceable on our current plan). Each project repo carries only a thin caller: its project vault name, its `KEY=item/field` (or full `op://`) secret refs, and its own `OP_SERVICE_ACCOUNT_TOKEN`. Action SHA pins, bun pin, 1Password CLI pin, and most hardening live in that one central file — vetting and rolling out an update is one PR in one repo.
- **Platform credentials are not stored in GitHub.** Only `OP_SERVICE_ACCOUNT_TOKEN` lives in GitHub Actions secrets. `CLOUDFLARE_API_TOKEN` comes from `webops-prod-shared` (`op://webops-prod-shared/CLOUDFLARE/CLOUDFLARE_API_TOKEN`). `CLOUDFLARE_ACCOUNT_ID` comes from the project vault (`op://webops-prod-<project>/CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_ACCOUNT_ID` — item name and field name are both `CLOUDFLARE_ACCOUNT_ID`). Callers must **not** list either of those keys in the workflow `secrets` input — the reusable workflow manages them and **rejects** those keys if listed.
- **App secrets still end up on Cloudflare as Worker secrets** (see trade-offs below). 1Password is where we edit and rotate; each deploy **pushes** the values listed in the caller’s `secrets` input via `wrangler secret bulk`. That sync is **additive for declared keys only** — it is not a full reconcile of every secret bound on the Worker (see [Secret lifecycle](#secret-lifecycle-additive-sync-not-full-reconcile)).
- **All other deploy paths must be disabled or treated as break-glass.** Cloudflare Git / Workers Builds / dashboard auto-deploy for the Worker must be off when the project moves to this flow. Local `wrangler deploy`, personal API tokens, Terraform, and other IaC that push the same script remain parallel trust roots unless operators deliberately stop using them for routine ship.
- **GitHub controls this pipeline; it is not the sole deploy control plane.** Who can land commits on `main` / run workflows decides who can ship *via this reusable workflow*. Cloudflare dashboard rights, API tokens, and any remaining alternate path still allow ship outside GitHub. Migration must reduce those rights, not only add the Actions caller.

### Prerequisites (hard)

This workflow is **bun-only**:

- Committed `bun.lock` or `bun.lockb`.
- `package.json` script named `deploy` that runs Wrangler deploy (and forwards CLI args if you ever rely on them).
- **`wrangler` as a direct, version-pinned dependency** so `bun install --frozen-lockfile` materializes it under `node_modules`. The central workflow’s secret-upload step runs `bunx wrangler secret bulk` **with Cloudflare credentials and app secrets already in the job env**. Without a locked local install, `bunx` may resolve or cache a registry copy — that is exactly the unpinned-CLI-with-secrets surface this guide forbids.
- npm-only / yarn-only / pnpm-only Workers are **out of scope** for this workflow (pnpm remains approved on the Vercel path only).

### Named Wrangler environments: unsupported today

Named Wrangler environments (`environment` / `--env`) are **not supported** today. Do not set `environment` on callers. Multi-env Workers need a separate workflow, separate callers, or out-of-band handling.

### Caller shape (contract)

Prefer a **SHA-pinned** ref to the reusable workflow. `@main` tracks central-repo HEAD on every run: one bad merge to `yearn/yearn-gha` is trusted by every consumer on the next deploy. Branch protection on `yearn-gha` is necessary; it is not the same as pinning the workflow ref. Org policy should require SHA pins (or an equivalent approved-ref process); the example below uses a placeholder SHA.

```yaml
name: Deploy Worker

on:
  push:
    branches: [main]
  # Optional: rotate secrets or redeploy without a no-op commit
  workflow_dispatch:

concurrency:
  group: cloudflare-deploy-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    # Pin to a reviewed commit of yearn-gha, not floating @main, once policy requires it.
    uses: yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml@<sha>
    with:
      vault: webops-prod-my-worker
      secrets: |
        DATABASE_URL=my-worker/DATABASE_URL
        API_KEY=my-worker/API_KEY
      # Do not set `environment` — not supported today.
    secrets:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

`vault` must be a project vault `webops-prod-<project>` (not `webops-prod-shared`). Each `secrets` line is `KEY=item/field` resolved as `op://<vault>/item/field`, or a full `op://...` reference.

**Full `op://` refs:** the project service account can read only `webops-prod-shared` and its project vault. A full ref can still pull **any** item those two vaults hold into the runner and bulk-upload it as a Worker binding. Use full refs only for intentional shared **app** secrets. Treat every `secrets:` line as security-sensitive in PR review — never use full refs to casually dump shared-vault material into a Worker.

The reusable workflow order is fixed and intentional:

1. Checkout
2. Set up bun (pinned in central workflow)
3. **`bun install --frozen-lockfile` (no app or platform secrets in env yet)**
4. Validate vault name
5. Prepare `op://` refs → load from 1Password (`export-env: true`)
6. Validate Cloudflare credentials
7. `wrangler secret bulk` for declared keys (if any)
8. `bun run deploy`

Do not reorder forks or copies of this flow to install dependencies **after** secrets are loaded.

## Why we're doing this

Same drivers as the Vercel guide — uniform guardrails after TanStack, GitHub-gated *pipeline* access, and 1Password as the secrets edit/rotate source of truth — applied to Cloudflare Workers.

- **Supply-chain risk is no longer theoretical.** The TanStack incident (May 2026) showed a moved action tag + CI cache is enough to compromise a release pipeline. Per-project, hand-rolled Wrangler workflows have the same failure mode. A single central workflow with SHA-pinned actions, pinned tooling, and enforced branch protection gives every Worker repo the same hardened path — and one place to fix it when the next incident lands. **Mutable `@main` (or any floating ref) on the reusable workflow reintroduces a central single point of failure** unless consumers pin SHAs or an equivalent approved ref.
- **Deploy access and tokens sprawl across Cloudflare + GitHub.** Tokens in repo secrets, dashboard-only secrets, and one-off Actions files don’t share guardrails. Moving *this* path into a reusable GitHub Actions workflow puts that path under GitHub permissions we already manage, and puts secret *definition* under 1Password. It does not by itself revoke Cloudflare dashboard or API ship rights.
- **Secrets sprawl.** Today secrets live across host platforms (Vercel, Cloudflare, Render, DigitalOcean, etc.). They tend to be broadly available to each platform’s team members and often lack a single audit trail. Centralizing edit/rotate in 1Password gives one control plane with real access control and audit history. 1Password is end-to-end encrypted; platform env stores are decryptable by the platform operator.
- **The trade we're accepting (shared with Vercel):** running deploy on the GitHub runner exposes secrets to deploy-time code on infrastructure we orchestrate. We take that trade for governance and uniformity.
- **Runner exposure is not a short window.** After `load-secrets-action` with `export-env: true`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and every declared app secret remain in the job environment through **secret bulk and `bun run deploy`**. There is no unset step today. A hostile change to `package.json` `deploy`, Wrangler config, or a dependency invoked at deploy time does **not** need to edit the workflow YAML to see the full secret map. Treat those files as highly privileged on every PR. Install-before-secrets limits *install* lifecycle script theft; it does not limit *deploy* script theft.
- **The Cloudflare-specific trade:** Worker **runtime** secrets cannot stay only on the runner. Unlike the Vercel path (where secrets are inlined into the build output and **nothing secret is stored in Vercel’s env dashboard**), Cloudflare Workers need secrets available at request time via bindings. This flow therefore **uploads** secrets to Cloudflare with `wrangler secret bulk` on every deploy that declares them. Cloudflare holds a **runtime copy**; 1Password remains the **edit/rotate source of truth** for keys this pipeline knows about. We accept platform-side storage for Worker secrets because that is how Workers are designed — we do not reintroduce dashboard-as-source-of-truth or GitHub-as-source-of-truth for those values.

## How this differs from the Vercel guide

| Concern | Vercel flow | Cloudflare Workers flow |
| --- | --- | --- |
| Deploy mechanism | `amondnet/vercel-action` (`vercel pull → build → deploy --prebuilt`) | `bun install` → `wrangler secret bulk` → `bun run deploy` |
| Platform auth from 1Password | `VERCEL_TOKEN`, `VERCEL_ORG_ID` (shared); `VERCEL_PROJECT_ID` (project vault) | `CLOUDFLARE_API_TOKEN` (shared item `CLOUDFLARE`); `CLOUDFLARE_ACCOUNT_ID` (project vault) |
| Where app secrets live after deploy | Inlined into build output; **not** left in Vercel env store | Uploaded as **Worker secrets** on Cloudflare (runtime bindings) |
| Secret sync semantics | Build-time inject for declared keys | **Additive** upload of declared keys only; no automatic delete of removed keys |
| `environment` input | `preview` \| `production` (Vercel target) | **Not supported** today |
| Secrets on runner after load | Passed into action `build-env` | Ambient job env through bulk + deploy |
| PR previews / GitHub Deployments | Preview URLs + Deployment records via the Vercel action | Not part of the current reusable workflow |
| Package manager | bun or pnpm (v10+) | **bun only**, `--frozen-lockfile` |
| Disable vendor auto-deploy | Vercel Git integration off | Cloudflare Workers Git / Workers Builds / dashboard auto-deploy off for that Worker |
| Concurrency | Callers should set a group (see Vercel examples) | Callers **must** set a concurrency group (see caller shape) |

Shared unchanged: central public `yearn/yearn-gha`, thin callers, SHA-pinned **actions**, 1Password vault layout pattern, branch protection expectations, no `pull_request_target`, read-only default permissions on the Cloudflare caller.

## Guardrails

### 1Password vault & service-account layout

- Service accounts are granted access **per vault**, and their vault access is **immutable after creation** — scope changes mean minting a new service account.
- Layout, per [1Password’s CI/CD guidance](https://blog.1password.com/1password-service-accounts/) (dedicated task-scoped vault, read-only service account):
  - `webops-prod-shared` — secrets common across projects (single place to rotate). Readable by **every** project’s service account. Put only values that must be shared. Most shared app secrets should still be low or medium stakes.
  - **Exception — Cloudflare API token:** the shared **`CLOUDFLARE` item** (`CLOUDFLARE_API_TOKEN`) lives in `webops-prod-shared` by design so every project SA can deploy. That token is **high stakes**, not “lower-stakes shared fluff.” Collocating it with every project SA is an explicit blast-radius trade: compromise of **any** migrated repo’s `OP_SERVICE_ACCOUNT_TOKEN` (or of its `main` in a way that exfiltrates the token) can yield the shared deploy credential for the whole Cloudflare account scope of that token.
  - `webops-prod-<project>` — one vault per project. Holds `CLOUDFLARE_ACCOUNT_ID` and that Worker’s app secrets.
  - One **read-only service account per project**, granted exactly two vaults: `webops-prod-shared` + its own.
- **Keep secrets DRY:** every secret lives in exactly one vault. If a secret is needed by more than one project, it belongs in `webops-prod-shared` — never copy items between vaults (copies drift silently when the original rotates).
- Only `OP_SERVICE_ACCOUNT_TOKEN` lives in GitHub Actions secrets. Everything else — **including `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`** — comes from 1Password via `op://` refs resolved by the reusable workflow.
- **API token hygiene:**
  - Prefer a **dedicated deploy token**, not a personal account token.
  - Scope to the minimum Cloudflare permissions required to deploy and edit secrets for the Workers on this flow. In practice Cloudflare Workers tokens are often **account-scoped** (edit any script in the account), not single-Worker-scoped. Assume **cross-Worker blast radius** inside that account until proven otherwise with a tighter token layout.
  - Concrete permission set depends on current Cloudflare API token templates; at minimum plan for Workers Scripts edit, Workers Secrets / secret bulk, and whatever Account read the CLI requires. Record the exact permissions on the 1Password item notes when minting.
  - The workflow does **not** allowlist Worker script name. Project `wrangler` config chooses the script. With an account-wide token, a compromised `main` can target sibling Workers in the same account.
  - If isolation requirements tighten, **split tokens per account or per tier** into separate shared items and split SAs accordingly — do **not** paste the same token into every project vault “for convenience.” Trigger a split when more than one trust tier shares an account or when a single project’s risk profile does not justify sharing the deploy token with every other project SA.

### Deploy control plane (GitHub + Cloudflare)

- **This pipeline:** gated by GitHub (who can merge to `main`, who can run workflows, optional GitHub Environment reviewers on `OP_SERVICE_ACCOUNT_TOKEN`).
- **Still parallel after migration unless you remove them:**
  - Cloudflare dashboard deploy / secret edit
  - Workers Builds / Git-connected builds for that Worker
  - Local `wrangler deploy` with personal or leftover tokens (break-glass only; document when used)
  - Terraform or other IaC pushing the same Worker
- Migration is incomplete if the Actions caller is added but humans and other automation still ship from Cloudflare without the same review gates.

### Branch protection

- **Public repos on this flow must enforce a ruleset on `main`/`master`** (PR + ≥1 approval). Rationale: anyone who can land a commit on `main` can edit the workflow to exfiltrate the service-account token (and thus the Cloudflare API token and all vault secrets that SA can read). They can also change only `package.json` / lockfile / Wrangler config and exfiltrate via deploy-time code with secrets already in env.
- **Private repos on free plan cannot get enforceable protection the same way.** Putting a private Worker on this flow without an equivalent merge gate is **accept-risk / unsupported by default** — not a quiet side note. Prefer public + ruleset, or a plan that enforces protection on private repos, before storing an OP service-account token for production secrets.
- Use **rulesets** (current GitHub mechanism). **Org admins bypass rulesets by default** — for small orgs where many people are admin, the gate is weak; reduce admin sprawl or accept that admin accounts are outside the model.
- The central workflow repo (`yearn/yearn-gha`) is deploy infrastructure — every project that tracks a floating ref trusts its `main`. It must stay public (on our plan) and carry the same ruleset protection. Prefer consumer **SHA pins** so a single central merge is not live for all projects until they intentionally move the pin.

### Workflow hardening

- **Pin all actions to commit SHAs**, not tags (a moved tag = the TanStack attack surface). Prefer enabling the repo/org setting **“require SHA pinning”** so it’s enforced mechanically.
- **Pin the reusable workflow ref** (SHA) on callers when policy requires it; do not treat floating `@main` as equivalent to action SHA pins.
- **Pin Wrangler via the app lockfile.** Require `wrangler` as a direct dependency with an exact version; `bun install --frozen-lockfile` must install it. The central secret-bulk step uses `bunx wrangler` and must resolve that locked install — not `wrangler@latest` and not an open semver range resolved at deploy time with secrets in env. The project’s `deploy` script must use the same locked Wrangler (e.g. `wrangler deploy` / `bunx wrangler` from the local tree). Same intent as pinning the Vercel CLI in the Vercel guide.
- **Pin bun** and the 1Password CLI version consumed by `load-secrets-action` in the central workflow — part of the reusable workflow contract.
- Dependency installs use **bun** with **`bun install --frozen-lockfile`**, and **must run before** secrets are loaded. bun blocks dependency lifecycle scripts by default when `trustedDependencies` is unset — keep it that way. npm and yarn run install scripts by default and are **not** approved for this flow.
- Never use `pull_request_target`. Keep caller permissions read-only (`contents: read` is enough for the current Cloudflare reusable workflow). Fork PRs get no secrets and require maintainer approval to run — leave those defaults alone.
- **Do not echo secret values.** Avoid logging env dumps. Wrangler and app scripts may print secret **names**; treat Actions logs as sensitive. Prefer not to print full env or debug flags that dump bindings.
- **`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` must not appear in the caller `secrets` input.** The workflow rejects those keys so projects cannot override platform credentials through the app-secret channel.
- **Concurrency:** every caller must set a concurrency group (see caller shape) so parallel `main` pushes do not interleave secret bulk and deploy.

### Secret lifecycle (additive sync, not full reconcile)

1Password is the place we **edit and rotate** values this pipeline owns. Cloudflare holds runtime copies. The pipeline does **not** make Cloudflare’s secret set identical to 1Password:

| Event | What happens on the Worker |
| --- | --- |
| Key listed in caller `secrets` and present in 1Password | Uploaded/overwritten on each deploy via `secret bulk` |
| Key removed from caller `secrets` or from 1Password only | **Stays on the Worker** until explicitly deleted in Cloudflare |
| Secret created only in the Cloudflare dashboard and never listed in `secrets` | **Stays forever** unless deleted manually; CI will not overwrite keys it does not upload |
| Dashboard edit of a key that CI also uploads | Next successful bulk upload **overwrites** with 1Password |

**Removing a secret:**

1. Remove the key from the caller `secrets` block (and from 1Password when appropriate).
2. Delete the secret on the Worker in Cloudflare (`wrangler secret delete <KEY>` for the correct env, or dashboard).
3. Redeploy if code must stop expecting the binding.
4. Optionally inventory Worker secrets vs the caller list on a schedule for high-stakes Workers.

### Non-atomic secret then code

Order is always **secret bulk, then deploy**. They are two API operations:

| Failure | Effect |
| --- | --- |
| Bulk OK, deploy fails | Runtime secrets already match new 1Password values; previous code may still be live |
| Bulk OK, deploy ships bad code | New secrets + broken Worker |
| Concurrent runs without concurrency group | Interleaved bulk/deploy races |

There is no automatic rollback of secrets. To restore previous values: use 1Password history (or a known-good value), update the item, redeploy. To restore previous code: redeploy a known-good git SHA. Cloudflare’s newer “secrets with version / `--secrets-file` on deploy” patterns are **not** used by this workflow yet; do not assume atomic secret+code versions.

### Operations

- **Rotation (app secrets):** edit the value in 1Password → run the project’s deploy workflow (`workflow_dispatch` or re-run a successful run from the Actions tab). That reloads from 1Password and runs `wrangler secret bulk` again. Cloudflare will not pick up a 1Password change until a deploy runs. Confirm you are re-running the correct workflow for that Worker.
- **Rotation (API token):** mint/rotate the token in Cloudflare → update `webops-prod-shared` / `CLOUDFLARE` → only then revoke the old token. In-flight deploys may still hold the old token in memory until they finish; avoid revoking mid-fleet-deploy. Any project deploy that loads the shared vault picks up the new token on the next run.
- **Rotation (OP service account):** if a project SA token may be leaked, mint a new SA (vault grants are immutable — often a new SA), update the GitHub secret, revoke the old SA. If the SA could have been used to read the shared vault, **also rotate `CLOUDFLARE_API_TOKEN`** and any other shared secrets that SA could read.
- **Rotation (account id):** rare; update the project vault item if a Worker moves accounts, then redeploy.
- **Dashboard:** not the source of truth for secrets. Prefer not to edit secrets only in the dashboard. Non-secret config (routes, non-sensitive vars, limits) may still follow existing Wrangler config / dashboard practice; keep **secret** material on the 1Password → CI → `secret bulk` path, plus explicit deletes when removing keys.
- **Named environments:** not supported today.
- Optional hardening for high-stakes public repos: store `OP_SERVICE_ACCOUNT_TOKEN` in a **GitHub Environment with required reviewers**, so a workflow run that needs it gets a second approval.

### Logging and break-glass

- Assume Actions logs may retain secret **names** and error context; never `echo` values.
- Break-glass local deploy: document who did it, with which token scope, and re-run CI afterward so 1Password-driven bulk upload is authoritative again for declared keys.

## Migration checklist (per Worker repo)

Use this when moving a project onto the central flow (and when reviewing PRs against this spec):

1. Confirm the app is **bun** + committed lockfile; add `wrangler` as a **direct pinned dependency**; `deploy` script runs that Wrangler.
2. Create or confirm `webops-prod-<project>` vault; ensure item `CLOUDFLARE_ACCOUNT_ID` field `CLOUDFLARE_ACCOUNT_ID` exists.
3. Confirm shared `CLOUDFLARE` / `CLOUDFLARE_API_TOKEN` in `webops-prod-shared`; record exact CF token permissions on the item; accept or mitigate **account-wide / cross-Worker** blast radius.
4. Move app secrets into the project vault (DRY — shared values only in `webops-prod-shared`).
5. Mint a **read-only** service account for exactly `webops-prod-shared` + `webops-prod-<project>`; store token as repo secret `OP_SERVICE_ACCOUNT_TOKEN` (optional: GitHub Environment + required reviewers).
6. Add thin caller workflow pinned to a **reviewed SHA** of `yearn/yearn-gha/.github/workflows/cloudflare-deploy.yml` (or `@main` only under explicit accept-risk). Include **concurrency** group; do **not** set `environment` until multi-env is fixed.
7. **Disable and verify** Cloudflare Git / Workers Builds / dashboard auto-deploy for this Worker (check dashboard after toggle; note the product name in the PR).
8. Reduce routine human deploy rights on Cloudflare where ship should go through GitHub; document remaining break-glass paths.
9. Enable branch ruleset on `main` (PR + ≥1 approval) for **public** repos. Do not migrate private repos on free plan without an explicit accept-risk decision.
10. Run a deploy; confirm declared Worker secrets updated and app healthy; spot-check Actions logs for accidental value leaks.
11. Remove old GitHub secrets / stop treating dashboard-only entries as source of truth for values now in 1Password.
12. Inventory Worker secrets vs caller `secrets` list; delete orphan runtime secrets that should not remain bound.
13. Confirm no Terraform / other CI still deploys the same script on every merge without the same gates.

## Out of scope (for now)

- Cloudflare **Pages** (separate reusable workflow + guide extension if needed).
- PR preview Workers / automatic preview URL comments (Vercel-only today).
- Named Wrangler environments (`environment` / `--env`).
- Multi-account layouts beyond `CLOUDFLARE_ACCOUNT_ID` per project vault.
- Atomic secret+code version upload (`--secrets-file` / versions API).
- Automatic deletion of Worker secrets not listed in the caller input.
- Allowlisting Worker script name inside the reusable workflow.
- npm / yarn / pnpm as installers for this Cloudflare workflow.

## Related

- Vercel: [Vercel Deployment Operating Guide](https://hackmd.io/@murderteeth/B1aFfRIXMx)
- Implementation: `yearn/yearn-gha` — `.github/workflows/cloudflare-deploy.yml`, README section “Cloudflare Workers”
- Vercel caller shapes under `yearn/yearn-gha/examples/` (Katana APR, yvUSD APR, fapy-hook). Cloudflare caller shape is defined in this guide and the README until a dedicated `examples/` entry is added
- This document: `docs/cloudflare-deployment-operating-guide.md` (canonical for the Workers flow in this repo)
