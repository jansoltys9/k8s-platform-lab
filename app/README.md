# Application

This folder contains two small services used to demonstrate a Kubernetes deployment.

| Folder | What it does | Local check |
|---|---|---|
| `backend/` | Node.js HTTP API (`/api/hello`, `/healthz`, `/readyz`, `/metrics`) | `node --check app/backend/server.js` |
| `frontend/` | Vite web app that calls `/api/hello` | `(cd app/frontend && npm ci && npm run build)` |

Both folders have a Dockerfile. The images are published separately to GHCR.

## Changing a service

Use a feature/fix branch, open a PR to `main`, and wait for CI checks. **Merging a PR does not publish an image.** A service-specific release tag starts the image release and GitOps promotion:

- Backend example: `fix/backend-response` → `backend-v0.1.1`
- Frontend example: `feat/frontend-message` → `frontend-v0.1.1`

The release workflow updates only that service's image tag in `helm/platformlab/values.yaml`; Argo CD deploys it. Do not edit image tags by hand as part of a normal application release.

For the exact commands and version rules, see [A – Application changes](../docs/operations/A-APPLICATION.md). For the overall flow, see [CI/CD and development](../docs/CI-CD-AND-DEVELOPMENT-FLOW.md).
