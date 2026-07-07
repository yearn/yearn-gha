# Vercel deploy with 1Password

Reusable GitHub workflow for deploying Vercel projects with secrets resolved
from values passed by the calling workflow.

The workflow reads `OP_SERVICE_ACCOUNT_TOKEN`, `VERCEL_TOKEN`, and
`VERCEL_ORG_ID` from inherited org or repo secrets by name. `VERCEL_PROJECT_ID`
and app variables are passed by each repo as values or `op://` references. The
workflow resolves them inside the deployment job with `op run`; no Vercel
env-file inputs are required.

## Usage

```yaml
name: Deploy to Vercel

on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: yearn/gha/.github/workflows/vercel-1password-deploy.yml@main
    with:
      VERCEL_PROJECT_ID: op://webops-prod/my-app/VERCEL_PROJECT_ID
      secrets: |
        RPC_URL=op://webops-prod/my-app/RPC_URL
        WEBHOOK_SECRET=op://webops-prod/my-app/WEBHOOK_SECRET
      export-env: true
    secrets: inherit
```

See `examples/` for the current Katana APR, yvUSD APR, and fapy-hook shapes.
