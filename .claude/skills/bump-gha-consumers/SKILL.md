---
name: bump-gha-consumers
description: Bump the pinned yearn/yearn-gha SHA in every yearn repo that calls one of this repo's reusable workflows, open a PR per repo, and admin-merge it. Use when the user says "bump consumers", "update sha in all repos", "roll out yearn-gha", or /bump-gha-consumers. Supports dry run.
---

# bump-gha-consumers

Run `bump.sh` from this skill dir.

```
./bump.sh [--path <dir>] [--sha <sha>] [--dry-run] [--no-merge]
```

- `--sha`: target SHA. Default: `origin/main` HEAD of yearn/yearn-gha.
- `--path`: dir holding local checkouts (`<dir>/<repo>`). Missing repo → cloned there. Always temp worktree off `origin/<default>`, removed after.
- `--dry-run`: find consumers, print the diff per repo. No clone push, no PR, no merge.
- `--no-merge`: open PRs, skip merge.

Steps the script does:
1. `gh search code` for `yearn/yearn-gha/.github/workflows` in org `yearn`.
2. Per repo: shallow clone default branch, `sed` every `yearn/yearn-gha/.github/workflows/*.yml@<ref>` to the new SHA.
3. Skip repo if no change.
4. Branch `chore/bump-yearn-gha-<short>`, commit, push, `gh pr create`.
5. `gh pr merge --squash --admin --delete-branch` (bypasses branch protection; needs admin).

Before a real run: confirm `gh auth status` shows `matheus1lva`. Always dry-run first and show the user the list.
