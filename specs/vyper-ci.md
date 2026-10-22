# Reusable Vyper compile/test workflow

- **Status:** Implemented in `.github/workflows/vyper-ci.yml`.
- **Model:** `yearn/yearn-vesting-escrow` `.github/workflows/test.yaml` —
  `astral-sh/setup-uv`, pinned Python, `uv sync --locked`, compile, pytest.
- **Not Slither/Aderyn:** those tools do not analyze `.vy`.

## Decision

The reusable workflow installs uv/Python and runs caller-supplied compile and
optional test commands. The **Vyper compiler version is pinned by the caller**
in `pyproject.toml` / `uv.lock` (vesting-escrow: `vyper==0.4.3`), not by this
workflow downloading an unpinned wheel.

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `python-version` | no | `3.11.9` | Passed to setup-uv. |
| `uv-version` | no | `0.11.21` | uv release for setup-uv. |
| `sync-args` | no | `""` | Extra `uv sync --locked` args. |
| `compile-command` | **yes** | — | Compile entrypoint. |
| `test-command` | no | `uv run --locked pytest` | Test entrypoint. |
| `run-tests` | no | `true` | Skip tests when false. |
