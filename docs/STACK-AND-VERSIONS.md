# Versions and who manages them

**Snapshot from 13 October 2026** (live versions can change):

| Component | Last verified / pinned | Changed through |
|---|---|---|
| Kubernetes | v1.35.1 | Minikube |
| Backend / frontend | `v0.1.0` / `v0.1.0` | Independent app release tags |
| PlatformLab Helm chart | `0.1.1` | `helm/platformlab/Chart.yaml` |
| Argo CD / Traefik | chart `10.10.1` / `41.6.1` | Direct Helm upgrade |
| Monitoring (includes Alertmanager) | kube-prometheus-stack chart `92.2.0` | Argo CD monitoring Application |
| Metrics Server / Sealed Secrets | chart `3.14.0` / `2.20.0` | Argo CD child Applications |
| Storage | Minikube CSI HostPath + `platformlab-csi-wffc` | Minikube addon and GitOps |

**Check versions in your own lab:**

```bash
kubectl get nodes
kubectl -n platformlab-app get deployments \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
cat helm/platformlab/Chart.yaml
cat platform/argocd/CHART_VERSION platform/traefik/CHART_VERSION
helm list -A
kubectl -n argocd get applications
kubectl -n monitoring get pods,pvc
```

`helm list` shows direct Helm releases, **not necessarily charts rendered by Argo CD**. For a GitOps add-on, read its `gitops/apps/*.yaml` `targetRevision` and check the resulting Pod images. **Helm chart version**, **application image tag**, and **application version** are different values; don't increase them together by default. See [version rules](CHANGE-AND-RELEASE-GUIDE.md).
