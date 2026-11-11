# Daily use – existing full lab

This guide is for the **existing** Minikube profile `platformlab` (one control plane, two workers). For a new laptop, use [First-time setup](BOOTSTRAP-MODES.md).

### Start the lab

First start Docker Desktop and wait for the Docker Engine.

```bash
cd ~/Project/k8s-platform-lab
bash scripts/platformlab-env.sh start
bash scripts/platformlab-env.sh verify
bash scripts/platformlab-env.sh uis start
bash scripts/platformlab-env.sh uis open
```

`start` resumes an **existing** cluster, safely aligns the CSI addon (after checking PVC ownership), and checks readiness. `verify` is read-only. Neither command forces an Argo CD sync.

| UI | Local address |
|---|---|
| Application | <http://127.0.0.1:18080/> |
| Argo CD | <https://127.0.0.1:18081/> |
| Prometheus | <http://127.0.0.1:18090/> |
| Alertmanager | <http://127.0.0.1:18093/> |

The Argo CD UI uses HTTPS with a local self-signed certificate. If the UIs are not available, check the forwards:

```bash
bash scripts/platformlab-env.sh uis status
bash scripts/platformlab-env.sh uis logs
```

### Quick health check

```bash
kubectl --context platformlab get nodes
kubectl --context platformlab -n argocd get applications
kubectl --context platformlab -n platformlab-app get pods,hpa
curl -fsS http://127.0.0.1:18080/api/hello
```

### Stop safely

```bash
bash scripts/platformlab-env.sh stop
```

This stops forwards and Minikube. It **does not delete** the cluster or PVCs. CSI HostPath is a local lab driver, not a backup solution.

### Troubleshooting

```bash
bash scripts/platformlab-env.sh check    # overview, read only
bash scripts/platformlab-env.sh doctor   # deeper diagnostics, read only
kubectl --context platformlab get pods -A
kubectl --context platformlab -n monitoring get pvc
```

`start` automatically runs the safe storage reconcile. If storage still fails, check `bash scripts/platformlab-env.sh storage status --strict` and investigate; do not delete PVCs.
