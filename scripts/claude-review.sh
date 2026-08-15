#!/usr/bin/env bash
# Opt-in Claude review of a pull request.
#
# Fetches the PR, parses the opt-in tags at the bottom of the PR description
# (review=true, model=fable|opus|haiku), clones the PR head into a throwaway
# workdir, runs the review-pr skill (pinned from yearn/webops) headless, and
# prints the review — or posts it as a PR comment with --post.
#
# Usage: claude-review.sh [--check] [--post] [--force] <pr-url>
#   --check  only parse the opt-in tags: print review-requested=<bool> (and
#            model=<tag> when requested) then exit; lets CI decide whether to
#            load review credentials at all. Fails on an invalid model tag.
#   --post   post the review as a PR comment (default: print to stdout)
#   --force  local testing only: behave as if review=true were tagged
#
# Credentials: gh must be authenticated (gh auth login or GH_TOKEN). The
# claude CLI uses its logged-in account or ANTHROPIC_API_KEY. A .env file at
# the repo root is sourced if present (local testing; CI injects env instead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Canonical skill source, pinned. Bump the hash deliberately to pick up skill
# changes; never track a branch.
SKILL_REPO="yearn/webops"
SKILL_SHA="66979571a48094e379928ac378b89e0b31d4c244"
SKILL_PATH="skills/review-pr/SKILL.md"

DEFAULT_MODEL="opus"
SUPPORTED_MODELS="fable opus haiku"

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

CHECK=false
POST=false
FORCE=false
PR_URL=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=true ;;
    --post) POST=true ;;
    --force) FORCE=true ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) PR_URL="$arg" ;;
  esac
done
if [[ -z "$PR_URL" ]]; then
  echo "usage: claude-review.sh [--check] [--post] [--force] <pr-url>" >&2
  exit 2
fi

command -v gh >/dev/null || { echo "error: gh CLI is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
if [[ "$CHECK" != "true" ]]; then
  command -v claude >/dev/null || { echo "error: claude CLI is required (npm install -g @anthropic-ai/claude-code)" >&2; exit 1; }
fi

# Parse the opt-in tag block: contiguous key=value lines at the very bottom of
# the PR description (trailing blank lines ignored). Emits "review=... model=..."
# style lines for the keys found. Reads the body on stdin.
parse_tags() {
  awk '
    { sub(/\r$/, ""); lines[NR] = $0 }
    END {
      # skip trailing blank lines
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      # walk the contiguous tag block upward from the bottom
      first = last + 1
      while (first - 1 > 0 && lines[first - 1] ~ /^[A-Za-z_-]+=[^[:space:]]+$/) first--
      for (i = first; i <= last; i++) print lines[i]
    }
  '
}

pr_json="$(gh pr view "$PR_URL" --json number,url,body,headRefOid,headRepository,headRepositoryOwner,isCrossRepository)"
pr_number="$(jq -r '.number' <<<"$pr_json")"
pr_url="$(jq -r '.url' <<<"$pr_json")"
head_sha="$(jq -r '.headRefOid' <<<"$pr_json")"
repo="${pr_url#https://github.com/}"; repo="${repo%/pull/*}"

# Same-repo PRs only. The workflow enforces this too; this keeps the script
# safe to point at arbitrary PRs.
if [[ "$(jq -r '.isCrossRepository' <<<"$pr_json")" == "true" ]]; then
  echo "error: ${pr_url} is from a fork; only same-repo pull requests are reviewed" >&2
  exit 1
fi

tags="$(jq -r '.body // ""' <<<"$pr_json" | parse_tags)"
tag() { grep -m1 "^$1=" <<<"$tags" | cut -d= -f2- || true; }

if [[ "$(tag review)" != "true" && "$FORCE" != "true" ]]; then
  [[ "$CHECK" == "true" ]] && echo "review-requested=false"
  echo "review not requested: PR description has no 'review=true' tag at the bottom; skipping" >&2
  exit 0
fi

model="$(tag model)"
model="${model:-$DEFAULT_MODEL}"
if ! grep -qw "$model" <<<"$SUPPORTED_MODELS"; then
  echo "error: unsupported model tag 'model=${model}'; supported: ${SUPPORTED_MODELS// /|}" >&2
  exit 1
fi

if [[ "$CHECK" == "true" ]]; then
  echo "review-requested=true"
  echo "model=${model}"
  exit 0
fi

echo "reviewing ${pr_url} at ${head_sha} with model=${model}" >&2

workdir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/claude-review.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

gh repo clone "$repo" "$workdir/repo" -- --quiet
cd "$workdir/repo"
gh pr checkout "$pr_number" >/dev/null

# Install the pinned review-pr skill as a project skill in the workdir.
mkdir -p .claude/skills/review-pr
gh api "repos/${SKILL_REPO}/contents/${SKILL_PATH}?ref=${SKILL_SHA}" --jq '.content' \
  | base64 -d > .claude/skills/review-pr/SKILL.md

prompt="$(cat <<EOF
Review pull request ${pr_url} using the review-pr skill installed in this project (.claude/skills/review-pr).

You are running non-interactively as an automated reviewer. Adaptations to the skill for this run:
- The PR author opted in to this automated review by tagging the PR description; that is the user approval the skill requires. Do not ask for or wait on confirmation.
- Do NOT post anything to GitHub or run any mutating gh command; the wrapper script posts the review. Read-only gh commands are fine.
- Skip the Playwright/browser/visual verification steps entirely; do not start dev servers.
- The npm-policy skill is not available here. If package.json changed, list newly added dependencies in the Dependencies section and note they were not policy-evaluated.
- The repository is already checked out at the PR head in the current directory.

Your final message must be exactly the review in the skill's Review Format, as raw markdown with no preamble, code fence, or commentary — it is posted verbatim as a PR comment.
EOF
)"

review_file="$workdir/review.md"
claude -p "$prompt" \
  --model "$model" \
  --output-format text \
  --allowedTools "Read,Grep,Glob,Bash,WebFetch" \
  > "$review_file"

if [[ ! -s "$review_file" ]]; then
  echo "error: claude produced an empty review" >&2
  exit 1
fi

cat >> "$review_file" <<EOF

---
_Automated opt-in review: \`model=${model}\`, head \`${head_sha:0:7}\`, skill pinned at [\`${SKILL_SHA:0:7}\`](https://github.com/${SKILL_REPO}/blob/${SKILL_SHA}/${SKILL_PATH})._
EOF

if [[ "$POST" == "true" ]]; then
  gh pr comment "$pr_url" --body-file "$review_file"
  echo "posted review comment on ${pr_url}" >&2
else
  cat "$review_file"
fi
