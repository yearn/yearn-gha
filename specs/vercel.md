# Vercel Deployment Operating Guide

- **Date:** 2026-07-04
- **Context:** Follow-up to the TanStack npm supply-chain incident (May 2026) and review of katana-apr-service #51

## What we do today

- Projects deploy via **Vercel's native Git integration**: Vercel builds on its own infra on every push; secrets live in each project's **Vercel env dashboard**, with shared/linked env vars for secrets common across projects.
- Permissions are split across two systems: **GitHub** controls who can change the code, **Vercel** controls who can deploy it and who can read its secrets.
- Only Vercel team members can trigger deploys/previews. Adding people to the Vercel team has a per-seat cost, and on our current plan membership is over-permissive for what most contributors actually need.


## What we're moving to

1Password becomes the **source of truth for deploy secrets**. Per project:

- A GitHub Actions deploy workflow (push to `main`) loads secrets from 1Password via `1password/load-secrets-action`, then deploys with `amondnet/vercel-action` (runner-side `vercel pull → build → deploy`), inlining secrets into the build output via `next.config.ts` `env`. The action also posts preview URLs on PRs and registers GitHub Deployments.
- The deploy workflow is defined **once**, as a reusable workflow (`workflow_call`) in a central repo (`yearn/yearn-gha`, which must be **public** so branch protection is enforceable on our plan). Each project repo carries only a thin caller: its project name, its `op://` secret refs, and its own `OP_SERVICE_ACCOUNT_TOKEN`. Action SHA pins, CLI version, and all hardening live in that one central file — vetting and rolling out an update is one PR in one repo.
- **Nothing secret is stored in Vercel's env dashboard.**
- The project's **Vercel Git integration must be disabled** when it moves to this flow — otherwise Vercel auto-builds (including PR previews) run against an empty env store and fail or misbehave.
- Deploy access is controlled by **GitHub permissions** (who can land commits on `main` / run workflows), not Vercel team membership — no extra Vercel seats needed to let someone ship.

## Why we're doing this

Deploy secrets and permissions are currently managed per-project across Vercel and GitHub, with no uniform guardrails; the TanStack incident showed how pipelines like that get exploited.

- **Supply-chain risk is no longer theoretical.** The TanStack incident (May 2026) showed a moved action tag + CI cache is enough to compromise a release pipeline. Our current per-project, hand-configured setup has no uniform guardrails. A single central workflow with SHA-pinned actions, an exactly-pinned CLI, and enforced branch protection gives every repo the same hardened path — and one place to fix it when the next incident lands.
- **Deploy access is coupled to Vercel seats.** Only Vercel team members can deploy, seats cost money, and membership on our plan grants far more than deploy rights. Moving the pipeline into GitHub Actions puts deploy access under GitHub permissions — which we already manage carefully — and frees us from buying seats for contributors who only need to ship.
- **Secrets sprawl.** Today secrets live across various host platforms like Vercel, Render, DigitalOcean, etc. They tend to be broadly available to each platform's team members and don't usually have audit reports. Centralizing in 1Password gives us one source of truth with real access control, audit history, and one place to rotate a shared secret. It's also a trust-model upgrade: Vercel's env store is decryptable by Vercel itself — the 2026 Vercel breach exposed platform-side env vars — while 1Password is end-to-end encrypted, so its servers can't decrypt what they hold.
- **The trade we're accepting:** building on the GitHub runner exposes secrets to build-time code (Vercel-native builds never put secrets on a runner we manage). We take that trade for governance, uniformity, and GitHub-controlled deploy access — and the guardrails below exist to make that exposure as small as we can.

## Guardrails

### 1Password vault & service-account layout

- Service accounts are granted access **per vault**, and their vault access is **immutable after creation** — scope changes mean minting a new service account.
- Layout, per [1Password's CI/CD guidance](https://blog.1password.com/1password-service-accounts/) (dedicated task-scoped vault, read-only service account):
  - `webops-prod-shared` — secrets common across projects (single place to rotate). Readable by every project's service account, so **only genuinely common, lower-stakes secrets** belong here.
  - `webops-prod-<project>` — one vault per project.
  - One **read-only service account per project**, granted exactly two vaults: `webops-prod-shared` + its own.
- **Keep secrets DRY:** every secret lives in exactly one vault. If a secret is needed by more than one project, it belongs in `webops-prod-shared` — never copy items between vaults (copies drift silently when the original rotates).
- Only `OP_SERVICE_ACCOUNT_TOKEN` lives in GitHub Actions secrets. Everything else — **including `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID`** — comes from 1Password via `op://` refs.

### Branch protection

- **Public repos configured to use this build flow must enforce branch protection on `main`/`master`** (PR + ≥1 approval). Rationale: anyone who can land a commit on `main` can edit the workflow to exfiltrate the service-account token.
- We cannot enforce protection on private repos (free plan limitation).
- Use **rulesets** (the current GitHub mechanism). Note: org admins bypass rulesets by default — the gate is advisory for admin accounts.
- The central workflow repo (`yearn/yearn-gha`) is deploy infrastructure — every project's deploy trusts its `main`, so it must be public and carry the same ruleset protection as any repo on this flow.

### Workflow hardening

- **Pin all actions to commit SHAs**, not tags (a moved tag = the TanStack attack surface). Prefer enabling the repo/org setting **"require SHA pinning"** so it's enforced mechanically.
- **Pin the Vercel CLI to an exact version via the `vercel-version` input** (in the central workflow). `amondnet/vercel-action` provisions the CLI itself (`npx vercel@<version>`), but its default is a semver range (`^50.0.0`) resolved at every run — unpinned, a brand-new (possibly compromised) release would be pulled and executed with secrets in env.
- Dependency installs use **bun or pnpm (v10+)**, both of which block dependency lifecycle scripts by default (bun: `trustedDependencies` unset; pnpm: no `onlyBuiltDependencies` allowlist) — keep it that way. npm and yarn run install scripts by default and are not approved for this flow.
- Never use `pull_request_target`. Keep default workflow permissions read-only. Fork PRs get no secrets and require maintainer approval to run — leave those defaults alone.

### Operations

- **Rotation:** secrets are inlined at build time and frozen per-deploy. Rotate in 1Password → **re-run the project's deploy workflow** (repo Actions tab). Nothing on Vercel's side can pick up a rotated value.
- **Runtime toggles** (e.g. debug flags read via `process.env` but not inlined) still work through Vercel's env dashboard and take effect on next deploy without a rebuild of secrets — the dashboard isn't dead, it's just no longer where secrets live.
- Optional hardening for high-stakes public repos: move the GitHub secret into a **GitHub Environment with required reviewers**, so a workflow run touching it needs a second approval.
