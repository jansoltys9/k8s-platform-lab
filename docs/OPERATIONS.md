# What are you changing?

Start in the repository root on an up-to-date `main`. Choose **one** guide; each contains an example branch name, the version rule, commands and a live check.

| Case | What changes? | Example branch | New version? | Instructions |
|---|---|---|---|---|
| **A – App** | Backend/frontend code or Dockerfile | `fix/backend-response` | Yes, for that service | [A](operations/A-APPLICATION.md) |
| **B – Pipeline** | GitHub Actions or release script | `ci/update-checkout` | No app version | [B](operations/B-PIPELINE.md) |
| **C – Helm/GitOps** | App memory, HPA, probes, policies, app Argo config | `config/backend-memory` | Only chart version if appropriate | [C](operations/C-HELM-GITOPS.md) |
| **D – Platform** | Monitoring/Alertmanager, Traefik, Argo CD, add-ons | `platform/monitoring-upgrade` | Only the relevant platform version | [D](operations/D-PLATFORM.md) |
| **Docs only** | `README.md`, `docs/**` | `docs/reviewer-clarity` | No | See below |

## Does a change start CI or deploy automatically?

| Changed files | App GitHub Actions | Deployment or update |
|---|---|---|
| `README.md`, `docs/**` only | **No** (normal PR/push) | None |
| `app/**` | Yes | New app release requires a SemVer Git tag |
| `.github/workflows/publish-images.yml`, `.github/scripts/**`* | Yes for configured paths | No new app image without a release tag |
| `helm/platformlab/**` | Yes | App Argo CD auto-syncs tracked `main` changes |
| `gitops/apps/**` | **No** | Root Argo CD Application needs **manual Sync**; child may then auto-sync |
| `platform/monitoring/values-minikube.yaml` | **No** | Monitoring child Application can auto-sync values changes |
| `platform/argocd/**`, `platform/traefik/**` | **No** | **Manual Helm upgrade** after merge, for installed releases |

*For `.github/scripts`, only `promote-images.py` is included in the current CI trigger paths. `workflow_dispatch` always lets you run the workflow deliberately. This table describes the current [application workflow](https://github.com/jansoltys9/k8s-platform-lab/blob/main/.github/workflows/publish-images.yml), not every possible GitHub workflow.

## Example: documentation only

```bash
git switch main
git pull --ff-only origin main
git switch -c docs/reviewer-clarity
# Edit README.md or docs/...
git diff --check
git add README.md docs/
git commit -m "docs: clarify reviewer steps"
git push -u origin docs/reviewer-clarity
```

Open a PR, review the Markdown and links, then merge. **No Docker build, version tag or Argo CD rollout.** It is normal for the app workflow to be absent/skipped on this PR.

**Every other change:** branch → edit → relevant checks → PR → merge → deploy/sync if required → verify. Do not change plaintext Secrets in Git, move published tags, or manually edit Argo CD-owned Deployments.
