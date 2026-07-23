# Infisical secret management + Vercel sync (replaces 1Password in vercel-deploy.yml)

## Decisions (user-confirmed)
- App runtime secrets: **native Infisical → Vercel secret sync** (configured in Infisical, not GHA).
- GHA fetches **only deploy creds** (`VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`) from Infisical.
- Auth: **OIDC machine identity** (no static secret in GitHub).
- Build runs **on Vercel** (drop local prebuilt flow entirely).
- **Infisical Cloud**, 1Password fully replaced.

## Target architecture

```
Infisical Cloud
├── project: webops-prod-shared
│     └── /deploy-config: VERCEL_TOKEN, VERCEL_ORG_ID (prod env)
├── project: webops-prod-<app>
│     ├── /deploy-config: VERCEL_PROJECT_ID (duplicated in preview + prod envs)
│     ├── /: app secrets per env
│     └── Secret Syncs (sensitive=true, per env) ──→ Vercel project env vars (preview/production)
└── 2 OIDC machine identities per app repo:
      preview: subject repo:yearn/<repo>:pull_request
      prod:    subject repo:yearn/<repo>:ref:refs/heads/main
      each: read-only on /deploy-config paths of shared + app project ONLY
```

App secrets never pass through GHA. Isolating creds at `/deploy-config` matters because
`Infisical/secrets-action` exports **every** secret at the selected path — no per-key
selector — so fetching from the project root would pull all app secrets onto the runner.

## Workflow changes (`.github/workflows/vercel-deploy.yml`)

### Inputs/secrets (breaking change for callers)
| before | after |
|---|---|
| `vault` (1P vault name) | `project-slug` (Infisical project, e.g. `webops-prod-<app>`) |
| `secrets` (KEY=item/field map) | **removed** — app secrets live in Infisical→Vercel sync |
| `environment` (preview\|production) | unchanged |
| secret `OP_SERVICE_ACCOUNT_TOKEN` | **removed**; new input `identity-id` — caller passes the env-matching identity (identity IDs are documented safe to commit; auth comes from OIDC claims + per-identity project grants) |

Output `deployment-url` unchanged.

### Job steps (after)
1. Checkout.
2. Guard: fail fast unless `github.event_name != 'pull_request' || head.repo == github.repository` — enforced here, not caller advice (fork PRs also lack `id-token` anyway; this makes the failure explicit).
3. Validate: `environment` ∈ {preview, production}; `project-slug` matches `webops-prod-*` and ≠ `webops-prod-shared`; map env slug `production→prod`, `preview→preview`.
4. `Infisical/secrets-action` (pinned sha), `method: oidc`, `identity-id: ${{ inputs.identity-id }}`: fetch `VERCEL_TOKEN` + `VERCEL_ORG_ID` from `webops-prod-shared`, env `prod`, `secret-path: /deploy-config`.
5. Same action: fetch `VERCEL_PROJECT_ID` from `${{ inputs.project-slug }}`, mapped env slug, `secret-path: /deploy-config`.
6. Validate the 3 creds non-empty.
7. Deploy via `amondnet/vercel-action` **without** `vercel-build`/`experimental-api`/`build-env`; plain CLI `vercel deploy` uploads source, Vercel builds remotely with synced env vars. In CLI mode the action's `target` input is not forwarded — pass `vercel-args: ${{ inputs.environment == 'production' && '--prod' || '' }}`. Keep `github-comment`, `github-deployment`, `github-deployment-environment`.

### Steps removed
- bun setup (no local build), 1P load-secrets, `prepare-project-secret-references`, `prepare-build-env`.

### Permissions
Job (and callers) additionally need `id-token: write`. Keep `contents: read`, `deployments: write`, `pull-requests: write`.

## Infisical-side setup (operational, documented in README)
1. Projects: `webops-prod-shared` + one per app. **Pro plan effectively required**: Free caps at 3 projects; shared + existing apps (katana-apr, yvusd-apr, fapy-hook, dummy) exceeds it. Custom `preview` env slug is also Pro-gated.
2. Env slugs per app project: `preview` + `prod` (custom slugs, Pro).
3. Vercel App Connection (Vercel API token) + per-app, per-env Secret Syncs: **sensitive=true**, Auto-Sync on. Note: Vercel only redacts sensitive values ≥32 chars in build logs.
4. Two OIDC identities per repo (subjects above); issuer `https://token.actions.githubusercontent.com`, audience = org URL. Setup note: repos created after 2026-07-15 use immutable-ID subject format (`repo:yearn@OWNER_ID/...`) — inspect actual token claims when configuring, don't assume the legacy format.
5. Grants: each identity reads only the `/deploy-config` paths it needs; no overlap between app projects (prevents cross-deploy if a caller swaps `identity-id`/`project-slug`).

## Migration / cutover (per app, in order)
1. Inventory the app's existing Vercel env vars — including branch-scoped preview vars (create branch-scoped syncs or explicitly drop that use case) and sensitive vars (values not readable via API; re-enter manually in Infisical).
2. Populate Infisical; initial sync mode **import-from-destination (Infisical wins)** — never "overwrite" on first sync; diff Vercel vs Infisical before trusting auto-sync.
3. Verify the app builds remotely on Vercel (root dir, install/build cmds, bun/package-manager version, private deps) — the Bun pin and local build disappear; one dummy run doesn't prove the other apps.
4. Land workflow repo change → re-pin consumer sha → green preview + production runs.
5. Revoke the app's 1P access last; `webops-prod-shared` 1P vault dies only after the last app migrates.

## Consumer changes (`yearn-practice-dummy/.github/workflows/vercel-deploy.yml`)
- Drop `vault`, `secrets:` block, `OP_SERVICE_ACCOUNT_TOKEN`, and `workflows-ref` (not declared by the new workflow).
- Add `project-slug: webops-prod-dummy`, `identity-id: ${{ github.event_name == 'pull_request' && '<preview-uuid>' || '<prod-uuid>' }}`, `permissions: id-token: write`.
- Re-pin `uses:` sha (consumer currently points at branch `fix/vercel-1p-env-sync`, reconcile when shipping).

## Docs
- Rewrite `README.md` (usage, inputs, Infisical setup + migration sections).
- Update `examples/*` callers.

## Accepted risks / non-goals
- Shared `VERCEL_TOKEN` blast radius across apps: parity with today's 1P `webops-prod-shared` design; documented, not redesigned.
- No separate `v2` workflow file: callers pin shas, migration is per-app re-pin; breaking the input contract on main is acceptable here.
- No sync-status gating in the workflow: auto-sync is near-immediate; cutover verifies sync status manually, README notes the stale-secret window and recommends checking sync status in Infisical after secret changes.
- GH `environment:` protection rules on the deploy job: optional hardening, out of scope (current workflow lacks it too).

## Open questions (need user answer before implementation)
1. Confirm Infisical **Pro plan** (project count + custom `preview` env slug both require it).
2. Two identities per repo with the caller selecting per-env `identity-id` — OK, or prefer single identity (simpler, but any branch could fetch prod deploy creds)?

## Verification plan
1. `actionlint` passes on the new workflow.
2. Dummy consumer PR → preview deploy green, PR comment with URL, confirm **no app secrets appear in runner env/logs**.
3. Change an app secret in Infisical → appears in Vercel env vars (sensitive) → redeploy picks it up.
4. Push to dummy main → confirm the deployment is actually **production** (check Vercel dashboard target, not just the GH deployment record).
