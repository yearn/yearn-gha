#!/usr/bin/env bash
set -euo pipefail
SHA="" DRY=0 MERGE=1 LOCAL=""
while [ $# -gt 0 ]; do
  case $1 in
    --sha) SHA=$2; shift 2 ;;
    --path) LOCAL=${2%/}; shift 2 ;;
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
WTS=() UNMERGED=()
cleanup() {
  for W in "${WTS[@]+"${WTS[@]}"}"; do
    git -C "${W%%|*}" worktree remove --force "${W#*|}" 2>/dev/null || true
    git -C "${W%%|*}" branch -qD "$BRANCH" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
echo "target sha: $SHA"
REPOS=$(gh search code "yearn/yearn-gha/.github/workflows" --owner yearn --json repository -L 200 --jq '.[].repository.nameWithOwner' | sort -u | grep -v '^yearn/yearn-gha$' || true)
for R in $REPOS; do
  D="$WORK/${R//\//_}"
  L="${LOCAL:-$WORK/repos}/${R#*/}"
  git -C "$L" rev-parse --git-dir >/dev/null 2>&1 || gh repo clone "$R" "$L" -- -q
  DB=$(gh repo view "$R" --json defaultBranchRef --jq .defaultBranchRef.name)
  git -C "$L" fetch -q origin "$DB"
  git -C "$L" worktree add -q --detach "$D" "origin/$DB"
  WTS+=("$L|$D")
  FILES=$(grep -rlE "$PAT" "$D/.github/workflows" 2>/dev/null || true)
  [ -n "$FILES" ] || { echo "skip $R: no match"; continue; }
  for F in $FILES; do sed -i.bak -E "s#($PAT)[^[:space:]]+#\1$SHA#g" "$F" && rm "$F.bak"; done
  if git -C "$D" diff --quiet; then echo "skip $R: already $SHORT"; continue; fi
  echo "== $R"; git -C "$D" --no-pager diff --stat
  if [ $DRY = 1 ]; then git -C "$D" --no-pager diff -U0 | grep '^[-+] '; continue; fi
  git -C "$D" switch -qC "$BRANCH"
  git -C "$D" commit -qam "ci: bump yearn-gha to $SHORT"
  git -C "$D" push -qfu origin "$BRANCH"
  URL=$(gh pr view -R "$R" "$BRANCH" --json url,state --jq 'select(.state=="OPEN").url' 2>/dev/null || true)
  [ -n "$URL" ] || URL=$(gh pr create -R "$R" -H "$BRANCH" -t "ci: bump yearn-gha to $SHORT" -b "Bump pinned yearn/yearn-gha reusable workflows to $SHA.")
  echo "pr: $URL"
  if [ $MERGE = 1 ] && gh pr merge "$URL" --squash --admin --delete-branch; then echo "merged $URL"; else UNMERGED+=("$URL"); fi
done
echo
echo "unmerged PRs: ${#UNMERGED[@]}"
for U in "${UNMERGED[@]+"${UNMERGED[@]}"}"; do echo "  $U"; done
