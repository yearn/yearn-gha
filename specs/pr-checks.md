# Reusable PR-check workflow (lint / format / typecheck / test)

- **Date:** 2026-08-20
- **Status:** Implemented in `.github/workflows/pr-checks.yml`. Not committed; consumer pins are still placeholders.
- **Context:** Companion to `specs/doppler-vercel.md`. That workflow deploys; this one gates the pull request.
  It handles no secrets and never authenticates to Doppler.

## Decision

One reusable workflow runs the four standard checks for every web app in the fleet. It reads the repository's
lockfile to pick a package manager and reads `package.json` to decide which checks exist. A check that the
repository does not define reports "skipped" instead of failing the job.

Consumers add a small caller workflow pinned to a full commit SHA, the same convention as `vercel-deploy.yml`.

Two properties define the design:

- **Discovery over configuration.** Callers pass no script names, no package manager, no matrix. Adding a
  `typecheck` script to a repository is what turns the typecheck step on.
- **Absent is not failing.** Missing scripts are normal in this fleet. The dummy repository defines only `lint`.

## Non-goals

- **No `build` check.** The Vercel deployment workflow builds every pull request already, and for Next.js
  `next build` typechecks. Adding a build step here duplicates a slower job.
- **No secrets, no OIDC, no `id-token: write`.** This workflow runs untrusted pull-request code, so it must not
  hold credentials. Anything needing a credential belongs in the deploy workflow.
- **No fork gate.** Fork pull requests are allowed to run checks; the workflow has nothing worth stealing.

## Workflow shape

`.github/workflows/pr-checks.yml`, `on: workflow_call`, one job `checks` on `ubuntu-latest`,
`timeout-minutes: 15`, `permissions: contents: read`.

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `node-version` | no | `'22'` | Node version for `actions/setup-node`. Ignored when the package manager is bun. |

No outputs. No secrets.

### Steps

1. **Checkout** — `actions/checkout` pinned to a full SHA, with `persist-credentials: false`.
2. **Detect package manager** — first lockfile match wins; exports `pm`/`PM` and `locked`/`LOCKED`.
3. **Enable corepack** — pnpm and yarn only, before `setup-node`.
4. **Setup Bun** — `oven-sh/setup-bun` at a pinned `bun-version` when the manager is bun.
5. **Setup Node** — `actions/setup-node` otherwise; the `cache:` input is empty when no lockfile exists.
6. **Install dependencies** — frozen-lockfile install per manager, or `npm install` when unlocked.
7. **Lint / Format / Typecheck / Test** — one step each, guarded by a `jq` script lookup.

### Package-manager detection

| Lockfile | Manager | Install |
| -------- | ------- | ------- |
| `bun.lock` or `bun.lockb` | bun | `bun install --frozen-lockfile` |
| `pnpm-lock.yaml` | pnpm | `pnpm install --frozen-lockfile` |
| `yarn.lock` | yarn | `yarn install --immutable` |
| `package-lock.json` or `npm-shrinkwrap.json` | npm | `npm ci` |
| none | npm (`locked=false`) | `npm install` |

The unlocked branch exists because both `setup-node`'s cache and `npm ci` fail hard without a lockfile. A
repository with no committed lockfile should still get its checks, in a degraded but honest form.

`corepack enable` must precede `setup-node`: the `cache: pnpm` and `cache: yarn` inputs fail when the binary is
absent, and corepack is what installs it.

### Script discovery

Each check step resolves the first script name that exists:

| Step | Script names | Notes |
| ---- | ------------ | ----- |
| Lint | `lint` | |
| Format | `format:check` | No `format` fallback — see below |
| Typecheck | `typecheck`, `type-check` | |
| Test | `test` | |

The guard is `jq -e --arg s "$script" '.scripts[$s] // empty | select(length > 0)' package.json`. The
`select(length > 0)` clause matters: plain `jq -e` treats `"lint": ""` as present and would run `$PM run ""`.

Each check is a separate step so the pull-request UI shows per-check status rather than one opaque pass/fail.

> A check that cannot fail must not report success. A skipped step says "skipped" in its log; a step that runs
> a write-mode command and exits 0 lies.

### Why no `format` fallback

The first implementation tried `format:check` and fell back to `format`. A conventional `format` script
(`prettier --write .`) rewrites the working tree and exits 0 whatever the input looked like, so the Format
check could only ever fail on a formatter crash. Repositories without `format:check` now report skipped.

Rejected alternatives:

- **Run `format` and then `git diff --exit-code`.** Works, but makes the workflow's verdict depend on a script
  whose contract it cannot see. A repository that wants the check adds `format:check`.
- **Append `--check` to the `format` script.** Assumes prettier's flag spelling across every formatter.

## Security posture

This workflow executes untrusted pull-request code — dependency install scripts and `package.json` scripts run
with whatever the runner holds. The controls follow from that:

- `persist-credentials: false` keeps `GITHUB_TOKEN` out of `.git/config` on the runner.
- `permissions: contents: read` at the job, nothing else. No `id-token`, no write scopes.
- No secrets are passed by callers, so `secrets: inherit` must never appear in a caller.
- Third-party actions are pinned to full commit SHAs; `bun-version` is pinned to an exact release rather than
  `latest`, so a Bun release cannot change what runs without a commit here.

Residual risk: a malicious dependency still executes on the runner. The blast radius is a read-only checkout and
the runner's own network access. Do not add credentials, deployment permissions, or a cache shared with trusted
workflows to this job.

## Caller shape

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
    uses: yearn/yearn-gha/.github/workflows/pr-checks.yml@<approved-sha> # full commit SHA only
```

Concurrency lives in the caller so a new push supersedes an in-flight run for the same ref.

## Rollout

1. Commit `.github/workflows/pr-checks.yml` in `yearn/yearn-gha`.
2. Replace `<approved-sha>` in `examples/pr-checks.yml` and in each consumer's caller with that full SHA.
3. Open a pull request on `yearn/yearn-practice-dummy`: `lint` runs; format, typecheck, and test report skipped.
4. Add the check to branch protection once it has passed on a real pull request.

Current state: the reusable workflow and the dummy caller both exist locally and are untracked. The dummy caller
still reads `@<approved-sha>`, which is not a resolvable ref — step 1 must land before it can be pinned.

## Known limits

- **The dummy repository runs one check.** It defines only `lint`, so format, typecheck, and test are skipped on
  every pull request. A green PR-checks run there does not mean the code typechecks; the Vercel build covers
  that. Adding the scripts is what enables the checks.
- **`node-version` is ignored for bun repositories.** Documented on the input; bun supplies its own runtime.
- **Bun installs are uncached.** `setup-node`'s cache does not cover bun and no separate cache step was added.
  Revisit if install time becomes the bottleneck.

## References

- Repo implementation: `yearn/yearn-gha` — `.github/workflows/pr-checks.yml`, `examples/pr-checks.yml`
- Design notes: `docs/plans/pr-checks.md`
- Companion spec: `specs/doppler-vercel.md`
- Harness: `yearn/yearn-practice-dummy` — `.github/workflows/pr-checks.yml`
