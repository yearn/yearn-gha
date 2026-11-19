# Reusable Aderyn analysis workflow

- **Status:** Implemented in `.github/workflows/aderyn.yml`.
- **Companion to:** Slither reusable workflow. Aderyn covers a different detector
  set; neither analyzes Vyper.

## Decision

Download a pinned Cyfrin/aderyn release tarball and verify its SHA-256 before
install. Default `fail-on: high`. Default `--path-excludes lib` (overridable).

## Why not Cyfrin/aderyn-ci

The marketplace action (`Cyfrin/aderyn-ci@v0`) installs with
`npm install -g @cyfrin/aderyn@0.6` — a floating minor and an npm global install
with lifecycle scripts. yearn-gha reviews require commit-SHA action pins and
reject unpinned CLI installs (`vercel@latest`, default `bun-version: latest`).
A verified release tarball meets that bar.

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `fail-on` | no | `high` | `high` or `any`. |
| `path-excludes` | no | `lib` | Aderyn `-x` value; empty disables. |
| `root` | no | `.` | Project root. |
| `aderyn-version` | no | `aderyn-v0.6.8` | Release tag. |
| `aderyn-sha256` | no | (linux x86_64 tarball hash) | Must match the tag. |
| `install-foundry` | no | `true` | Install Foundry before Aderyn. |
| `foundry-version` | no | `stable` | Foundry channel. |
| `submodules` | no | `recursive` | Checkout submodule mode. |
