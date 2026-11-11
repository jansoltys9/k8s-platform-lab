# A – Application or Dockerfile change

**Use this for:** `app/backend/**`, `app/frontend/**`, or either Dockerfile.

**Result:** a *new version of one service*. The Git tag starts GitHub Actions; it builds/scans, publishes to GHCR and updates `helm/platformlab/values.yaml`. Argo CD deploys the new image.

## Example A1: fix the backend (`v0.1.0` → `v0.1.1`)

**1. Make the fix on a branch**

```bash
git switch main
git pull --ff-only origin main
git switch -c fix/backend-response
# Edit app/backend/server.js in VS Code.
node --check app/backend/server.js
docker build -t platformlab-backend:local ./app/backend
git add app/backend/
git commit -m "fix(backend): correct API response"
git push -u origin fix/backend-response
```

Open a **PR to `main`**. Wait for validation/Trivy; merge the PR. A PR and a normal `main` push do **not** publish a release.

**2. Select the merged application commit and create a release tag**

```bash
git switch main
git pull --ff-only origin main
git fetch --tags origin
git log -5 --oneline -- app/backend
```

Choose the SHA of **your merged backend fix** from that output. Check it before tagging:

```bash
RELEASE_COMMIT="PASTE_FULL_OR_SHORT_SHA_HERE"
git show -s --format='%h %s' "$RELEASE_COMMIT"
git merge-base --is-ancestor "$RELEASE_COMMIT" origin/main
# Confirm backend-v0.1.1 does not already exist:
git tag -l 'backend-v0.1.1'
git ls-remote --tags origin 'refs/tags/backend-v0.1.1'
```

Only if that tag is unused, and the chosen commit includes the release workflow, continue:

```bash
git tag -a backend-v0.1.1 "$RELEASE_COMMIT" -m "Release backend v0.1.1"
git push origin backend-v0.1.1
```

**Do not tag a bot commit** such as `chore(gitops): ... [skip ci]`; it may skip the release workflow. If the code or Docker image must change again, use a **new** version, never overwrite a published tag.

**3. Check GitHub and Kubernetes**

```bash
gh run list --workflow publish-images.yml --limit 5
# Wait for "Publish release to GHCR" and "Promote ... to GitOps" to succeed.
git pull --ff-only origin main
kubectl -n argocd get application platformlab
kubectl -n platformlab-app rollout status deploy/platformlab-backend --timeout=180s
kubectl -n platformlab-app get deploy platformlab-backend platformlab-frontend \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

Expected: backend `:v0.1.1`; frontend stays at its old version. If Argo CD is still catching up, check again after sync.

## Example A2: frontend bug or feature

Same steps, but use `fix/frontend-header` (or `feat/frontend-search`), edit `app/frontend/`, and release `frontend-v0.1.1` (or next valid version). Local check:

```bash
(cd app/frontend && npm ci && npm run build)
docker build -t platformlab-frontend:local ./app/frontend
```

After PR merge, pick the **frontend** merge commit (`git log -5 --oneline -- app/frontend`) and create `frontend-vX.Y.Z` on that commit. Verify `deployment/platformlab-frontend` and make sure backend did not change.

## Example A3: base image security update

Changed only `app/backend/Dockerfile`? This is still **A**, not B. Branch `fix/backend-base-image`, open a PR, then issue a new backend PATCH release. CI builds/scans the new image; do not manually `docker push`.

**Version reminder:** PATCH `0.1.0 → 0.1.1` = fix/rebuild; MINOR `0.1.1 → 0.2.0` = backward-compatible feature. For breaking changes in the `0.x` phase, call out compatibility in the PR.

**If a run fails:** `gh run view RUN_ID --log-failed`. Fix the source through a PR. Do not force-move a tag; publish corrected content under the next unused version.
