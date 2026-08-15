# Claude PR Review Operating Guide (Doppler)

- **Date:** 2026-08-15
- **Status:** Implemented in `yearn/yearn-gha`; tested locally via `scripts/claude-review.sh`. Doppler config, identities, and downstream rollout are operational work.
- **Context:** Companion to the Vercel deploy design (`specs/doppler-vercel.md`); reuses its OIDC posture, shared-project layout, and pinning rules. Matches the reusable workflow in `.github/workflows/claude-review.yml`.

## Decision

Downstream repositories get automated PR reviews from Claude, opt-in per PR, using the same `review-pr` skill used in local review sessions. GitHub Actions authenticates to Doppler with OIDC to fetch `ANTHROPIC_API_KEY`; GitHub stores no static Anthropic or Doppler credential.

Reviews are **opt-in**: nothing runs unless the PR author adds tags to the bottom of the PR description. Untagged PRs skip before any credential is loaded.

## Opt-in tags

Tags are contiguous `key=value` lines at the very bottom of the PR description (trailing blank lines are ignored; a tag block anywhere else in the body does not count):

```
review=true
model=fable
```

- `review=true` — required to enable the review. The author's tag is the approval the `review-pr` skill otherwise collects interactively; the posted comment is that consent's output.
- `model=fable|opus|haiku` — optional; defaults to `opus` (latest Opus). Only Claude models are supported. An invalid value fails the check visibly rather than silently defaulting.

Every push to the PR (`opened`, `synchronize`, `reopened`) re-runs the check against the current description; each opted-in push gets a fresh review comment. An in-flight review is cancelled when a new push arrives (per-PR concurrency group).

## Architecture

The review logic lives in `scripts/claude-review.sh`, runnable identically on a laptop and in CI; the reusable workflow is a thin wrapper. The script:

1. Fetches the PR with `gh` and rejects cross-repository (fork) PRs.
2. Parses the opt-in tag block; exits cleanly when `review=true` is absent.
3. Clones the repo into a throwaway workdir and checks out the PR head.
4. Installs the `review-pr` skill from `yearn/webops` **pinned to a full commit SHA** (`SKILL_SHA` in the script — bump deliberately, never track a branch).
5. Runs `claude -p` headless with the tagged model and CI adaptations: no browser/visual verification, no `npm-policy` evaluation (new dependencies are listed but flagged as not policy-evaluated), and no GitHub writes by the model — the script itself posts.
6. Appends a footer (model, head SHA, pinned skill link) and posts the review as a single PR comment (`--post`), or prints it (default, used locally).

The workflow (`.github/workflows/claude-review.yml`) adds the CI shell:

- Rejects non-`pull_request` triggers and fork PRs before anything else (forks receive no OIDC token anyway).
- Checks out the script at the caller-supplied `scripts-ref` input. Callers pin it to the same approved commit SHA as the workflow itself — the `github` context does not expose the called workflow's own SHA (`job_workflow_sha` exists only as an OIDC claim), so the caller carries the pin.
- Runs `claude-review.sh --check` first with only `github.token`; Doppler is contacted only when the PR opted in.
- Fetches `ANTHROPIC_API_KEY` from `webops-shared-prod` / `review-configs` via `dopplerhq/secrets-fetch-action` (OIDC, SHA-pinned). Keep that config to the one secret: `inject-env-vars: true` exports everything in it onto the runner.
- Installs a pinned Claude Code CLI version and runs the script with `--post`.

## Doppler setup

- Add a `review-configs` config to `webops-shared-prod` holding only `ANTHROPIC_API_KEY` (a key scoped to review usage, revocable without touching deploys).
- Create a service-account identity per downstream repo (or one shared review identity) with **read on `webops-shared-prod` / `review-configs` only** — review identities must not read `deploy-configs`, and deploy identities must not read `review-configs`.
- Bind the identity's OIDC claims to `repository:yearn/<app>` and the exact `job_workflow_ref` of the pinned reusable workflow SHA, mirroring the deploy identities. Reviews run on `pull_request`, so no `ref` binding applies.
- Downstream repos store the identity ID in a repository variable (`DOPPLER_REVIEW_IDENTITY_ID`).

## Downstream usage

Stub in the app repo (see `examples/katana-apr-service/claude-review.yml`):

```yaml
name: Claude review

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  review:
    uses: yearn/yearn-gha/.github/workflows/claude-review.yml@<approved-sha> # full commit SHA
    with:
      identity-id: ${{ vars.DOPPLER_REVIEW_IDENTITY_ID }}
      scripts-ref: <approved-sha> # same SHA as the workflow pin above
```

## Local testing

No Doppler involved. `gh auth login` (or `GH_TOKEN`) plus a logged-in `claude` CLI or `ANTHROPIC_API_KEY` — optionally via a gitignored `.env` at the repo root (see `.env.example`), which the script sources automatically.

```sh
scripts/claude-review.sh <pr-url>            # respects opt-in tags, prints the review
scripts/claude-review.sh --force <pr-url>    # pretend review=true was tagged
scripts/claude-review.sh --check <pr-url>    # parse tags only (what CI gates on)
scripts/claude-review.sh --post <pr-url>     # actually posts the comment — use deliberately
```

## Security notes

- Fork PRs are rejected twice (workflow guard and script guard); they also receive no OIDC token.
- Only same-repo PRs can trigger a review, and only by editing their own PR description — the blast radius of an opt-in is one Claude API spend and one comment on that PR.
- The model runs with `gh` authenticated as the workflow token (`pull-requests: write`). The prompt forbids mutating commands and the script does the posting, but this is instruction-level, not capability-level, containment: a malicious same-repo PR could try to prompt-inject the reviewer. Same-repo authors already have push access, so this does not cross a trust boundary — but do not extend the workflow to forks or grant the job broader permissions.
- The review runs project code (linters, installs) on the runner, like any CI job for a same-repo PR.
- Pins to maintain deliberately: `SKILL_SHA` (skill content), `CLAUDE_CODE_VERSION` (CLI), action SHAs, and the caller's workflow + `scripts-ref` SHAs (kept identical).
