#!/usr/bin/env bash
set -euo pipefail
SHA="" DRY=0 MERGE=1
while [ $# -gt 0 ]; do
  case $1 in
    --sha) SHA=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-merge) MERGE=0; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done
[ -n "$SHA" ] || SHA=$(gh api repos/yearn/yearn-gha/commits/main --jq .sha)
SHORT=${SHA:0:7}
BRANCH="chore/bump-yearn-gha-$SHORT"
PAT='yearn/yearn-gha/\.github/workflows/[A-Za-z0-9_.-]*\.yml@'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "target sha: $SHA"
REPOS=$(gh search code "yearn/yearn-gha/.github/workflows" --owner yearn --json repository -L 200 --jq '.[].repository.nameWithOwner' | sort -u | grep -v '^yearn/yearn-gha$' || true)
for R in $REPOS; do
  D="$WORK/${R//\//_}"
  gh repo clone "$R" "$D" -- --depth 1 -q
  FILES=$(grep -rlE "$PAT" "$D/.github/workflows" 2>/dev/null || true)
  [ -n "$FILES" ] || { echo "skip $R: no match"; continue; }
  for F in $FILES; do sed -i.bak -E "s#($PAT)[^[:space:]]+#\1$SHA#g" "$F" && rm "$F.bak"; done
  if git -C "$D" diff --quiet; then echo "skip $R: already $SHORT"; continue; fi
  echo "== $R"; git -C "$D" --no-pager diff --stat
  if [ $DRY = 1 ]; then git -C "$D" --no-pager diff -U0 | grep '^[-+] '; continue; fi
  git -C "$D" switch -qc "$BRANCH"
  git -C "$D" commit -qam "ci: bump yearn-gha to $SHORT"
  git -C "$D" push -qu origin "$BRANCH"
  URL=$(gh pr create -R "$R" -H "$BRANCH" -t "ci: bump yearn-gha to $SHORT" -b "Bump pinned yearn/yearn-gha reusable workflows to $SHA.")
  echo "pr: $URL"
  [ $MERGE = 1 ] && gh pr merge "$URL" --squash --admin --delete-branch && echo "merged $URL"
done
