# Branch names and versions – quick rules

**Need exact commands?** Pick [A/B/C/D](OPERATIONS.md). This page is just the cheat sheet.

| Example change | Branch name | What version changes? |
|---|---|---|
| Fix backend API | `fix/backend-response` | Backend image `v0.1.0` → `v0.1.1` |
| Add a frontend feature | `feat/frontend-search` | Frontend image `v0.1.0` → `v0.2.0` |
| Update backend base image | `fix/backend-base-image` | Backend new PATCH release |
| Fix Actions workflow | `ci/update-checkout` | No application release |
| Increase backend RAM | `config/backend-memory` | No image change |
| Update Helm deployment template | `chart/backend-probe` | Our `Chart.yaml version` (usually PATCH) |
| Upgrade Alertmanager via monitoring chart | `platform/monitoring-upgrade` | `kube-prometheus-stack` chart pin, not app images |
| Tune Argo CD values | `platform/argocd-resources` | No chart bump for values-only change; manual Helm apply |
| Improve docs | `docs/reviewer-clarity` | No version |

**Three separate versions:** app Git tags `backend-vX.Y.Z` / `frontend-vX.Y.Z` (published images `vX.Y.Z`); our chart version in `helm/platformlab/Chart.yaml`; and third-party chart versions in GitOps or `platform/*/CHART_VERSION`.

PATCH = fix or secure rebuild; MINOR = compatible feature; MAJOR = breaking change. During `0.x`, document breaking changes clearly. The Helm `appVersion` is informational; it cannot describe two independently versioned services.

**Release tags:** use an approved *application commit* already merged to `main`, not an automatic `chore(gitops)` promotion commit containing `[skip ci]`. Never move or reuse an existing tag. [Application example](operations/A-APPLICATION.md).
