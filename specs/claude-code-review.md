# Claude Code Review Operating Guide

- **Date:** 2026-08-15
- **Status:** Implemented in `yearn/yearn-gha`. Complete the rollout runbook before enabling a caller repository.
- **Context:** This guide matches the reusable workflow in `.github/workflows/claude-code-review.yml`. It follows the same hardening posture as `specs/doppler-vercel.md`: SHA pins, event gates, fail-fast validation, minimal caller surface.

## Decision

GitHub Actions runs an on-demand Claude review on pull requests through the reusable workflow. A collaborator comments `/review` on a PR; the caller workflow (triggered by `issue_comment`) dispatches the reusable workflow. The workflow wraps [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) and is callable only through `workflow_call` — the caller supplies the trigger, the reusable workflow supplies the implementation, pins, and guards.

Authentication uses a **Claude Code OAuth token** (`claude setup-token`), not an Anthropic API key. The token is stored once in Doppler — `webops-shared-prod`, config `claude-review` — and fetched at run time: the workflow authenticates to Doppler as a service-account identity with the GitHub Actions OIDC token and injects the secret into the job env. Callers pass no secret at all; they only grant `id-token: write`. The workflow fails fast when the token resolves empty, so a misconfigured identity or config stops the run before the action executes.

The token gets its own config because the fetch action exports every secret in a config onto the runner: sharing `deploy-configs` would put `VERCEL_TOKEN` on review runners and the OAuth token on deploy runners.

The guide distinguishes two kinds of data:

- **Review credential:** `CLAUDE_CODE_OAUTH_TOKEN`. A long-lived credential tied to a Claude subscription. It reaches the runner and the action.
- **Review output:** PR comments. Posted with the workflow-scoped `GITHUB_TOKEN`, passed explicitly to the action as `github_token`; no extra GitHub credential is stored. Without the explicit pass the action falls back to a token from its own Claude GitHub App, whose permissions are independent of the job's `permissions` block.

## Implementation status (yearn-gha)

| Control | Status |
| ------- | ------ |
| `workflow_call` only — no direct trigger in the reusable workflow | Done |
| Reject anything that is not a `/review` comment on a PR before the action runs | Done |
| Reject commenters without write access (owner/member/collaborator) | Done |
| Reject fork PRs (head repo resolved via API) before the action runs | Done |
| Fetch `CLAUDE_CODE_OAUTH_TOKEN` from Doppler over OIDC (SHA-pinned `dopplerhq/secrets-fetch-action` `v2.0.0` / `451892f…`), after the event and fork gates | Done |
| Validate `CLAUDE_CODE_OAUTH_TOKEN` non-empty after the Doppler fetch and before the action runs | Done |
| `id-token: write` requested for the Doppler login only; no static credential in any caller | Done |
| SHA-pinned actions (`actions/checkout`, `anthropics/claude-code-action` `v1.0.193` / `9d7150b…`) | Done |
| Install `review-pr-workflow` (+ `review-pr`, `npm-policy`) from `yearn/webops-skills` pinned by `WEBOPS_SKILLS_SHA` | Done |
| Action `prompt` is a `/review-pr-workflow` invocation, not an inlined review rubric | Done |
| `--allowedTools` is read + git + lint + skill/workflow; no comment/write tools | Done |
| Review body from `structured_output.review`; a follow-up step posts `gh pr comment` | Done |
| PR checkout `persist-credentials: false`; one-shot extraheader fetch of `PR_BASE_REF` | Done |
| Explicit `github_token: ${{ github.token }}` so the action cannot fall back to its Claude App token | Done |
| Caller examples pin reusable workflow to full commit SHA | Done (examples use the `@<approved-sha>` placeholder; replace at rollout) |
| Per-repo prompt/model/turn customization | **Not built.** No inputs; see rejected alternatives. |

Remaining work is **operational**: create the Doppler identity and the `claude-review` config, store the token there, confirm `DOPPLER_IDENTITY_ID` in the workflow matches that identity, pin the approved SHA in callers, branch protection on `yearn/yearn-gha`.

## What this design protects—and what it does not

Controls provided:

- One reviewed implementation of event gates, pins, skill invocation, and tool allowlist. There are no inputs, so callers cannot widen the action's tool access at all. `--allowedTools` covers Read/Grep/Glob/Skill/Task/Agent/Workflow/WebFetch, read-only `gh`/`git`, and lint package managers — not Write/Edit, and not `gh pr comment`. The comment is posted by a later step from `structured_output`.
- Anything that is not a `/review` PR comment from a commenter with write access on a same-repo PR fails before the action executes, so the token is never exercised outside the intended context. Unlike `pull_request`, `issue_comment` runs with repository secrets regardless of who comments — the author-association and fork guards are what stand between a drive-by commenter and the token.
- Full-SHA pins on both the action and the reusable workflow prevent a moved tag from silently changing executed code.
- The workflow requests only `contents: read`, `pull-requests: write`, and `id-token: write`, and passes its own `github.token` to the action, so GitHub operations are bounded by those permissions. `id-token: write` serves the Doppler login alone; the pinned action's own OIDC federation path stays unused.
- No caller repository stores the review credential. The token exists in one Doppler config, read by one identity, and reaches a runner only for the duration of a run.

Risks that remain:

- `CLAUDE_CODE_OAUTH_TOKEN` is a long-lived credential on the runner for the duration of the run. The Doppler fetch is short-lived, the token it returns is not; there is no OIDC equivalent for the Claude credential itself today. Storage and rotation are now centralized (one Doppler secret, `claude setup-token` again). **Accepted risk — state it plainly:** a compromised run can read the token.
- The Doppler identity trusts every caller repository in the org, so any workflow in any org repository can authenticate as it and fetch the token directly — not only this reusable workflow. **Accepted risk — state it plainly:** the workflow's gates bound what this workflow does with the token, not who else in the org can read it.
- The reviewed code executes nothing, but Claude reads the PR contents; a malicious same-repo PR can still prompt-inject. Blast radius is larger than “comments only”: Claude can run `git`/lint and spawn subagents. **Residual risk — state it plainly.** It still cannot push (`persist-credentials: false`) or merge.
- The commenter gate trusts `author_association`. Owners, members, and collaborators can spend review tokens at will; there is no rate limit beyond per-PR concurrency cancellation in the caller.
- Review comments are advisory. The workflow is not a required check and must not gate merges; Claude review does not replace human review.

## Target architecture

- A small caller workflow in each repository triggers on `issue_comment` (`types: [created]`) and invokes the SHA-pinned reusable workflow.
- The reusable workflow owns the gates (fail closed), writes `PR_BASE_REF` from the same PR API call, checks out the PR head (`refs/pull/<n>/head`, `fetch-depth: 0`, `persist-credentials: false`), fetches the base with a one-shot `http.extraheader` bearer, installs `review-pr-workflow` / `review-pr` / `npm-policy` from `yearn/webops-skills` at `WEBOPS_SKILLS_SHA`, then fetches the OAuth token from Doppler over OIDC and validates it non-empty.
- The action `prompt` is `/review-pr-workflow <repo>/pull/<n>`. Claude does not post. `--json-schema` requires a `review` string; the next step posts it with `gh pr comment`, same as `examples/test-failure-analysis.yml`. The PR head is already checked out.
- There is no per-caller customization; the skill pin, prompt, and tool allowlist live only in the reusable workflow. Bump the skill by changing `WEBOPS_SKILLS_SHA` in a reviewed PR, same as other pins.

Rejected alternatives:

- **`anthropic_api_key` auth.** The fleet standard is subscription OAuth tokens; no API-key billing per repo. The action supports both; the workflow deliberately exposes only the OAuth path to keep one rotation story.
- **Automatic review on every push (`pull_request` trigger).** Reviews every commit whether wanted or not; token spend scales with push volume, and most runs are cancelled or ignored. The `/review` comment makes each spend a deliberate human action.
- **Interactive `@claude` mention mode.** The action's conversational mode needs a broader permission surface than a single fire-and-forget review. Out of scope; explicitly future — the trigger plumbing (`issue_comment`, commenter gate) now exists, so it is cheap to add behind a reviewed change.
- **Direct `issue_comment` trigger inside the reusable workflow.** Would make this repo review its own PRs only. `workflow_call` keeps one implementation for many callers, matching `vercel-deploy.yml`.
- **Per-caller Actions secret (`CLAUDE_CODE_OAUTH_TOKEN`).** The pre-pivot design: each caller stored the token and passed it explicitly or through `secrets: inherit`. It puts the same long-lived credential in N repositories, and rotation means N manual updates that drift. Doppler holds one entry and one identity; callers hold nothing.
- **Per-caller `prompt` / `claude-args` inputs.** Existed in an earlier draft; removed. Every input is surface a caller can get wrong (a `claude-args` override that drops `--allowedTools` silently posts nothing; a copied allowlist drifts from the central one). Repos that need a different review skill or pin can propose it here, keeping one reviewed implementation. Explicitly future if a real need appears — the input plumbing is a small reviewed diff.
- **Inlined quality/bugs/security/performance prompt.** Replaced by the pinned Yearn `review-pr-workflow` skill so the rubric lives in `yearn/webops-skills`, not this workflow. The action prompt is only the invocation plus non-interactive CI constraints.

### Caller shape

```yaml
name: Claude code review

on:
  issue_comment:
    types: [created]

concurrency:
  group: claude-review-${{ github.event.issue.number }}
  cancel-in-progress: true

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  review:
    uses: yearn/yearn-gha/.github/workflows/claude-code-review.yml@<approved-sha> # full commit SHA only
```

`concurrency` groups by PR number (`issue_comment` runs on the default branch ref, so `github.ref` cannot tell PRs apart); cancellation makes a newer `/review` supersede an in-flight review of the same PR.

### Workflow inputs and secrets

No inputs. No secrets — the workflow resolves its credential from Doppler. The caller must grant `id-token: write`; a reusable workflow cannot exceed the caller's token permissions, so without it the Doppler login fails.

No outputs.

## GitHub controls

- Pin `anthropics/claude-code-action`, `actions/checkout`, `dopplerhq/secrets-fetch-action`, and `WEBOPS_SKILLS_SHA` to full commit SHAs; version comments are informational only. Upgrade through reviewed changes.
- Callers pin the reusable workflow to a full commit SHA. Update in a reviewed rollout.
- Protect the default branch of `yearn/yearn-gha`; this repo is shared CI infrastructure. CODEOWNERS on `.github/workflows/**`.
- Store `CLAUDE_CODE_OAUTH_TOKEN` only in Doppler (`webops-shared-prod` / `claude-review`), with Masked visibility so the fetch action registers GitHub log redaction. Do not commit it, and do not add it as an Actions secret or variable in any caller.
- Keep the `claude-review` config to that one secret; the fetch action exports the whole config onto the runner.
- Do not use `pull_request_target`. Do not mark the review job as a required status check.
- Grant callers only `contents: read`, `pull-requests: write`, and `id-token: write`.

## Rollout runbook

1. Generate the token: `claude setup-token` (requires a Claude subscription). Create the `claude-review` config in `webops-shared-prod` and store the token there as `CLAUDE_CODE_OAUTH_TOKEN`, visibility Masked.
2. Create the Doppler service-account identity with OIDC (discovery/issuer URL `https://token.actions.githubusercontent.com`), trust the caller repositories, grant it read on `webops-shared-prod` / `claude-review` only, and confirm `DOPPLER_IDENTITY_ID` in the workflow matches that identity. Binding `job_workflow_ref` to this reusable workflow is optional; without it any org workflow with `id-token: write` can fetch the token (accepted risk above).
3. Merge the reusable workflow; record the approved full commit SHA.
4. Add the caller workflow (see `examples/claude-code-review/`), pinned to that SHA, granting `id-token: write`.
5. Open a test PR and comment `/review`; confirm the review posts a top-level comment and inline comments, that a second `/review` cancels the in-flight run, and that a `/review` from a non-collaborator account fails at the gate.
6. When the token owner leaves or the token leaks, regenerate with `claude setup-token` and update the one Doppler secret; old tokens are revoked from the Claude account settings.

## References

- [claude-code-action](https://github.com/anthropics/claude-code-action)
- [claude-code-action usage docs](https://github.com/anthropics/claude-code-action/blob/main/docs/usage.md)
- [claude-code-action solutions (automated review example)](https://github.com/anthropics/claude-code-action/blob/main/docs/solutions.md)
- [Reusing workflows (secrets and permissions)](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- Skills: `yearn/webops-skills` — `review-pr-workflow`, `review-pr`, `npm-policy` (pin `WEBOPS_SKILLS_SHA`)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/claude-code-review.yml`
- Caller examples: `examples/claude-code-review/`
