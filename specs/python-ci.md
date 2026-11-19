# Reusable Python CI workflow

- **Status:** Implemented in `.github/workflows/python-ci.yml`.
- **Model:** `yearn/monitoring` `.github/workflows/ci.yml` — three jobs
  (`test`, `lint`, `audit`) with `astral-sh/setup-uv`, `uv python install`,
  `uv sync --locked --extra dev`, `ruff check`, `ruff format --check`,
  `ty check`, `uv audit --preview-features audit-command`, `uv run pytest tests/`.

## Decision

Only the steps monitoring actually runs are included. No extra linters, no
coverage upload, no invented tools.

## Inputs

| Name | Required | Default | Description |
| ---- | -------- | ------- | ----------- |
| `sync-args` | no | `--extra dev` | Extra `uv sync --locked` args. |
| `test-command` | no | `uv run pytest tests/` | Test job command. |
| `run-lint` | no | `true` | Enable lint job. |
| `run-tests` | no | `true` | Enable test job. |
| `run-audit` | no | `true` | Enable audit job. |
