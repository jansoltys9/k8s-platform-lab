# C – Change Helm or application GitOps

**Use for:** `helm/platformlab/**`, app ConfigMaps/HPA/RBAC/NetworkPolicies or `gitops/apps/platformlab.yaml`. A config-only change **doesn't need a new Docker image**.

## Example C1: raise backend memory limit

```bash
git switch main
git pull --ff-only origin main
git switch -c config/backend-memory
# In helm/platformlab/values.yaml change backend.resources.limits.memory
# e.g. from 256Mi to 384Mi. Leave the image tags unchanged.
helm lint ./helm/platformlab
helm template platformlab ./helm/platformlab -n platformlab-app >/tmp/platformlab.yaml
git diff --check
git add helm/platformlab/values.yaml
git commit -m "chore(helm): increase backend memory limit"
git push -u origin config/backend-memory
```

PR → checks → merge → app Argo CD auto-sync:

```bash
kubectl -n argocd get application platformlab
kubectl -n platformlab-app get deploy platformlab-backend \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}{"\n"}'
```

Expected: new memory limit, unchanged image tags. **No** app version or chart version bump for a routine values change.

## Example C2: change a Helm template

Branch `chart/backend-probe`. Edit `helm/platformlab/templates/backend-deployment.yaml`, validate as above, bump `helm/platformlab/Chart.yaml` **`version`** for a template release (e.g. `0.1.1 → 0.1.2`), then PR and merge. `appVersion` is informational; both services retain separate image tags.

## Example C3: change the app Argo CD Application

Branch `gitops/app-sync-policy`. Edit `gitops/apps/platformlab.yaml`, review it, PR and merge. **Different from editing a Helm values file:** `platformlab-root` watches `gitops/apps/` without automated sync. **Manually Sync `platformlab-root` in the Argo CD UI**, then verify the child Application. No app image release is needed.

## Secrets and recovery

For Sealed Secrets use [full-lab setup](../FULL-LAB-SECRETS.md); commit only encrypted data. If a change breaks the app, revert it via Git PR. Don't manually `kubectl edit` or run `helm upgrade platformlab` against Argo CD-owned workloads.
