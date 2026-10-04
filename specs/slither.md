# Reusable Slither analysis workflow

- **Status:** Implemented in `.github/workflows/slither.yml`.
- **Model:** Caller-shaped after `yearn/yBOLD` `.github/workflows/slither.yml`
  (`crytic/slither-action`, `fail-on: medium`, Foundry install, recursive
  submodules). Deliberately not `yearn/yearn-vaults-v3`
  `.github/workflows/slither.yaml` (`continue-on-error: true`,
  `crytic/slither-action` v0.1.1).

## Decision

One `workflow_call` job runs Slither on the caller repository. It holds no
secrets and requests only `contents: read`. Findings at `medium` or higher
fail the job. Vendored `lib/` is excluded by default via `--filter-paths` and
is overridable.

## Non-goals

- No SARIF upload / code-scanning permissions (callers that need that can wrap
  this workflow later).
- No `continue-on-error`. A finding at the configured severity fails the check.
- Does not analyze Vyper (`.vy`). Use the Vyper compile/test workflow instead.

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `target` | no | `.` | Project path for Slither. |
| `fail-on` | no | `medium` | Severity floor that fails the job. |
| `filter-paths` | no | `lib/` | Passed as `--filter-paths`; empty disables. |
| `slither-args` | no | `""` | Extra Slither CLI args. |
| `slither-config` | no | `""` | Optional config path. |
| `install-foundry` | no | `true` | Install Foundry before Slither. |
| `foundry-version` | no | `stable` | Foundry version channel. |
| `submodules` | no | `recursive` | Checkout submodule mode. |

## Caller shape

Pin the reusable workflow to a full commit SHA. Grant `contents: read` only.
See `examples/slither.yml`.
