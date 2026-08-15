# Claude Code Review Operating Guide

- **Date:** 2026-08-15
- **Status:** Implemented in `yearn/yearn-gha`. Complete the rollout runbook before enabling a caller repository.
- **Context:** This guide matches the reusable workflow in `.github/workflows/claude-code-review.yml`. It follows the same hardening posture as `specs/doppler-vercel.md`: SHA pins, event gates, fail-fast validation, minimal caller surface.

## Decision

GitHub Actions runs an on-demand Claude review on pull requests through the reusable workflow. A collaborator comments `/review` on a PR; the caller workflow (triggered by `issue_comment`) dispatches the reusable workflow. The workflow wraps [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) and is callable only through `workflow_call` — the caller supplies the trigger, the reusable workflow supplies the implementation, pins, and guards.

Authentication uses a **Claude Code OAuth token** (`claude setup-token`), not an Anthropic API key. The token is a caller secret (`CLAUDE_CODE_OAUTH_TOKEN`); reusable workflows receive caller secrets only when passed explicitly or through `secrets: inherit`. The workflow declares the secret as required and additionally fails fast when it resolves empty, because `secrets: inherit` satisfies the required-secret check even when the caller never defined the secret.

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
| Validate `CLAUDE_CODE_OAUTH_TOKEN` non-empty before the action runs | Done |
| SHA-pinned actions (`actions/checkout`, `anthropics/claude-code-action` `v1.0.193` / `9d7150b…`) | Done |
| Review prompt + `--allowedTools` restricted to PR commenting, defined only in the reusable workflow | Done |
| Explicit `github_token: ${{ github.token }}` so the action cannot fall back to its Claude App token | Done |
| Caller examples pin reusable workflow to full commit SHA | Done (examples use the `@<approved-sha>` placeholder; replace at rollout) |
| Per-repo prompt/model/turn customization | **Not built.** No inputs; see rejected alternatives. |

Remaining work is **operational**: generate and store the token per caller (or org-wide), pin the approved SHA in callers, branch protection on `yearn/yearn-gha`.

## What this design protects—and what it does not

Controls provided:

- One reviewed implementation of event gates, pins, prompt, and tool allowlist. There are no inputs, so callers cannot widen the action's tool access at all; the `--allowedTools` list limits Claude to `gh pr comment`, `gh pr diff`, `gh pr view`, and inline review comments.
- Anything that is not a `/review` PR comment from a commenter with write access on a same-repo PR fails before the action executes, so the token is never exercised outside the intended context. Unlike `pull_request`, `issue_comment` runs with repository secrets regardless of who comments — the author-association and fork guards are what stand between a drive-by commenter and the token.
- Full-SHA pins on both the action and the reusable workflow prevent a moved tag from silently changing executed code.
- The workflow requests only `contents: read` and `pull-requests: write`, and passes its own `github.token` to the action, so GitHub operations are bounded by those permissions. `id-token: write` is not requested: at the pinned action SHA, OIDC serves only the federation auth path, which this workflow does not expose.

Risks that remain:

- `CLAUDE_CODE_OAUTH_TOKEN` is a long-lived credential on the runner for the duration of the run. There is no OIDC equivalent for it today; rotation is manual (`claude setup-token` again). **Accepted risk — state it plainly:** a compromised run can read the token.
- The reviewed code executes nothing, but Claude reads the PR contents; a malicious same-repo PR can attempt prompt injection to make the review post misleading comments. The tool allowlist bounds the blast radius to PR comments — it cannot push code, approve, or merge.
- The commenter gate trusts `author_association`. Owners, members, and collaborators can spend review tokens at will; there is no rate limit beyond per-PR concurrency cancellation in the caller.
- Review comments are advisory. The workflow is not a required check and must not gate merges; Claude review does not replace human review.

## Target architecture

- A small caller workflow in each repository triggers on `issue_comment` (`types: [created]`), gates on `/review` comments on PRs, and invokes the SHA-pinned reusable workflow.
- The reusable workflow re-checks the gates (fail closed, in case the caller's `if` is missing or wrong), resolves and checks out the PR head (`refs/pull/<n>/head`, `fetch-depth: 1`), and runs the action with the built-in prompt: review for code quality, bugs, security, performance; post feedback via `gh pr comment` and inline comments.
- There is no per-caller customization; the prompt and tool allowlist live only in the reusable workflow.

Rejected alternatives:

- **`anthropic_api_key` auth.** The fleet standard is subscription OAuth tokens; no API-key billing per repo. The action supports both; the workflow deliberately exposes only the OAuth path to keep one rotation story.
- **Automatic review on every push (`pull_request` trigger).** Reviews every commit whether wanted or not; token spend scales with push volume, and most runs are cancelled or ignored. The `/review` comment makes each spend a deliberate human action.
- **Interactive `@claude` mention mode.** The action's conversational mode needs a broader permission surface than a single fire-and-forget review. Out of scope; explicitly future — the trigger plumbing (`issue_comment`, commenter gate) now exists, so it is cheap to add behind a reviewed change.
- **Direct `issue_comment` trigger inside the reusable workflow.** Would make this repo review its own PRs only. `workflow_call` keeps one implementation for many callers, matching `vercel-deploy.yml`.
- **Per-caller `prompt` / `claude-args` inputs.** Existed in an earlier draft; removed. Every input is surface a caller can get wrong (a `claude-args` override that drops `--allowedTools` silently posts nothing; a copied allowlist drifts from the central one). Repos that need a different prompt can propose it here, keeping one reviewed implementation. Explicitly future if a real need appears — the input plumbing is a small reviewed diff.

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
  pull-requests: write

jobs:
  review:
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/review')
    uses: yearn/yearn-gha/.github/workflows/claude-code-review.yml@<approved-sha> # full commit SHA only
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

`concurrency` groups by PR number (`issue_comment` runs on the default branch ref, so `github.ref` cannot tell PRs apart); cancellation makes a newer `/review` supersede an in-flight review of the same PR.

### Workflow inputs and secrets

| Name | Kind | Required | Default | Description |
| ---- | ---- | -------- | ------- | ----------- |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | yes | — | Claude Code OAuth token from `claude setup-token`. |

No inputs.

No outputs.

## GitHub controls

- Pin `anthropics/claude-code-action` and `actions/checkout` to full commit SHAs; version comments are informational only. Upgrade through reviewed changes.
- Callers pin the reusable workflow to a full commit SHA. Update in a reviewed rollout.
- Protect the default branch of `yearn/yearn-gha`; this repo is shared CI infrastructure. CODEOWNERS on `.github/workflows/**`.
- Store `CLAUDE_CODE_OAUTH_TOKEN` as an Actions secret — repository-level per caller, or organization-level with an explicit repository allowlist. Do not commit it or place it in a variable.
- Do not use `pull_request_target`. Do not mark the review job as a required status check.
- Grant callers only `contents: read` and `pull-requests: write`.

## Rollout runbook

1. Generate the token: `claude setup-token` (requires a Claude subscription). Store as `CLAUDE_CODE_OAUTH_TOKEN` — org secret with allowlist, or per-repo secret.
2. Merge the reusable workflow; record the approved full commit SHA.
3. Add the caller workflow (see `examples/claude-code-review/`), pinned to that SHA.
4. Open a test PR and comment `/review`; confirm the review posts a top-level comment and inline comments, that a second `/review` cancels the in-flight run, and that a `/review` from a non-collaborator account fails at the gate.
5. When the token owner leaves or the token leaks, regenerate with `claude setup-token` and update the secret; old tokens are revoked from the Claude account settings.

## References

- [claude-code-action](https://github.com/anthropics/claude-code-action)
- [claude-code-action usage docs](https://github.com/anthropics/claude-code-action/blob/main/docs/usage.md)
- [claude-code-action solutions (automated review example)](https://github.com/anthropics/claude-code-action/blob/main/docs/solutions.md)
- [Reusing workflows (secrets and permissions)](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- Repo implementation: `yearn/yearn-gha` — `.github/workflows/claude-code-review.yml`
- Caller examples: `examples/claude-code-review/`
