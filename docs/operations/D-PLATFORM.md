# D – Update the platform or an add-on

**Use for:** monitoring/Alertmanager, Argo CD, Traefik, Metrics Server, Sealed Secrets and storage. **No backend/frontend release tag.** Upgrade one component at a time.

| What changes? | Git source | Who actually applies it? |
|---|---|---|
| Monitoring chart / bundled Alertmanager | `gitops/apps/monitoring.yaml` | Sync **root**, then monitoring child in Argo CD |
| Monitoring config only | `platform/monitoring/values-minikube.yaml` | Monitoring child auto-syncs |
| Argo CD chart/config | `platform/argocd/CHART_VERSION`, `values-minikube.yaml` | **Manual Helm upgrade** |
| Traefik chart/config | `platform/traefik/CHART_VERSION`, `values-minikube.yaml` | **Manual Helm upgrade** |

## D1 – Upgrade Alertmanager through the monitoring stack

**Example branch:** `platform/monitoring-upgrade`. Our Alertmanager comes from **kube-prometheus-stack**. We don't maintain a separate Alertmanager Helm release. Upgrading its chart can also change Prometheus and the Operator, so check release notes, CRDs and PVCs first.

```bash
git switch main
git pull --ff-only origin main
git switch -c platform/monitoring-upgrade
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
# Choose a TESTED version from release notes; don't guess one.
# Update targetRevision in gitops/apps/monitoring.yaml.
# Adjust platform/monitoring/values-minikube.yaml only if needed.
MONITORING_CHART_VERSION="$(awk '/targetRevision:/{print $2; exit}' gitops/apps/monitoring.yaml)"
helm template platformlab-monitoring prometheus-community/kube-prometheus-stack \
  --version "$MONITORING_CHART_VERSION" -n monitoring \
  -f platform/monitoring/values-minikube.yaml >/tmp/monitoring.yaml
git diff --check
git add gitops/apps/monitoring.yaml platform/monitoring/values-minikube.yaml
git commit -m "chore(platform): upgrade monitoring chart"
git push -u origin platform/monitoring-upgrade
```

PR → review chart/CRD changes → merge. This **platform-only PR does not run the app GitHub Actions workflow**. Because `platformlab-root` does not auto-sync its child definitions, open the Argo CD UI and **Sync `platformlab-root`**. The `platformlab-monitoring` child can then apply the new chart.

```bash
kubectl -n argocd get applications platformlab-root platformlab-monitoring
kubectl -n monitoring get pods,pvc
kubectl -n monitoring get pod alertmanager-platformlab-monitoring-kube-pr-alertmanager-0 \
  -o jsonpath='{.spec.containers[*].image}{"\n"}'
```

Expected: Applications healthy, Alertmanager running, PVCs Bound. Verify your real alerts. **No** manual `helm upgrade` here. For *Alertmanager configuration only*, edit the `alertmanager:` section of `platform/monitoring/values-minikube.yaml` on `config/alertmanager-settings`; child auto-syncs without a chart bump.

## D2 – Change the configuration of Argo CD itself

Example: adjust Argo CD controller resources. Branch `platform/argocd-resources`; edit `platform/argocd/values-minikube.yaml`. A values-only change **doesn't change** `platform/argocd/CHART_VERSION`.

```bash
git switch main
git pull --ff-only origin main
git switch -c platform/argocd-resources
# Edit platform/argocd/values-minikube.yaml.
git diff --check
git add platform/argocd/values-minikube.yaml
git commit -m "chore(platform): tune Argo CD resources"
git push -u origin platform/argocd-resources
```

PR → review → merge. **Important:** Argo CD is installed via direct Helm; a Git merge **does not apply this change**. In the full lab, plan maintenance and run:

```bash
git switch main && git pull --ff-only origin main
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm history argocd -n argocd --kube-context platformlab
helm template argocd argo/argo-cd -n argocd \
  --version "$(cat platform/argocd/CHART_VERSION)" \
  -f platform/argocd/values-minikube.yaml >/tmp/argocd.yaml
helm upgrade argocd argo/argo-cd -n argocd --kube-context platformlab \
  --version "$(cat platform/argocd/CHART_VERSION)" \
  -f platform/argocd/values-minikube.yaml --wait
kubectl -n argocd get pods,applications
```

**Chart upgrade?** Use branch `platform/argocd-upgrade`, change `platform/argocd/CHART_VERSION` too, and follow the same tested procedure after compatibility review. Don't modify Argo CD resources through a self-syncing Argo CD Application here; this lab uses direct Helm for the Argo CD release.

## D3 – Upgrade Traefik (direct Helm)

Branch `platform/traefik-upgrade`; change `platform/traefik/CHART_VERSION` and any necessary values. **Also update `TRAEFIK_CHART_VERSION` in `scripts/platformlab-bootstrap.sh`** so reviewer installations use the same version. PR → merge → planned Helm upgrade:

```bash
git switch main && git pull --ff-only origin main
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update
helm history traefik -n traefik --kube-context platformlab
helm template traefik traefik/traefik -n traefik \
  --version "$(cat platform/traefik/CHART_VERSION)" \
  -f platform/traefik/values-minikube.yaml >/tmp/traefik.yaml
helm upgrade traefik traefik/traefik -n traefik --kube-context platformlab \
  --version "$(cat platform/traefik/CHART_VERSION)" \
  -f platform/traefik/values-minikube.yaml --wait
kubectl -n traefik get pods
```

Afterwards test both `/` and `/api/hello` via Traefik. If something fails, inspect Pods and `helm history`; `helm rollback` is only appropriate after assessing CRD/migration compatibility, and Git pins must match the eventual state.

**For storage/other add-ons:** check their owner in the [repository map](../REPOSITORY-AND-GITOPS-MAP.md), then use the same branch → PR → controlled apply → verification approach. No reason to modify backend/frontend versions.
