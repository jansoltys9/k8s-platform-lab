# Kubernetes Platform Lab

A small frontend/backend application on Kubernetes, built to demonstrate secure deployments, CI/CD, GitOps, autoscaling and monitoring.

## Architecture

```text
Developer -> GitHub Actions (tests, Docker build, Trivy) -> GHCR
                           |                                 |
                           |                          SemVer images
                           v                                 |
                 GitOps promotion ---------------------------+
                           |
                  Git: Helm values
                           v
                       Argo CD -> Kubernetes
                                   |
                              Traefik Ingress
                              /            \
                         Frontend         Backend (/api, /metrics)
                                                 |
                                         Prometheus / Alertmanager
```

The application has **Deployments, ClusterIP Services, Ingress, ConfigMap, Secret, RBAC, Calico NetworkPolicies, CPU HPA, health probes, and non-root containers**. The full lab adds Argo CD App-of-Apps, Sealed Secrets and monitoring on three Minikube nodes.

## Quick start for reviewers

**Requirements:** Docker Desktop (Linux containers), Git/Git Bash, Minikube, kubectl, Helm, OpenSSL, internet access and at least **4 GiB available to Docker**.

```bash
git clone https://github.com/jansoltys9/k8s-platform-lab.git
cd k8s-platform-lab
bash scripts/platformlab-bootstrap.sh --mode demo --phase infra
bash scripts/platformlab-bootstrap.sh --mode demo --phase app
```

In **another terminal**:

```bash
kubectl --context platformlab-review -n traefik port-forward svc/traefik 18082:80
```

Open <http://127.0.0.1:18082/> and select **Call Backend API**, or run:

```bash
curl -f http://127.0.0.1:18082/api/hello
kubectl --context platformlab-review -n platformlab-app get deploy,pods,hpa
```

Stop without deleting the demo: `minikube stop -p platformlab-review`.

**Demo versus full lab:** the one-node demo intentionally skips Argo CD and Prometheus; it uses public GHCR images and generates its own local Secret. The separately demonstrated **full lab** includes GitOps and Prometheus/Alertmanager. Its setup is guided rather than a single unattended command; it requires more resources and a newly sealed Secret. See [first-time setup](docs/BOOTSTRAP-MODES.md) and [full-lab Secrets](docs/FULL-LAB-SECRETS.md).

## Where to go next

| You want to... | Read |
|---|---|
| Install a full GitOps lab | [Bootstrap modes](docs/BOOTSTRAP-MODES.md) |
| Start or stop an existing full lab | [Daily operations](docs/OPERATIONS-LIFECYCLE.md) |
| Change app, CI, Helm, monitoring or Argo CD | [Choose A/B/C/D](docs/OPERATIONS.md) |
| Understand versions and releases | [Release rules](docs/CHANGE-AND-RELEASE-GUIDE.md) |
| See architecture and ownership | [Repository map](docs/REPOSITORY-AND-GITOPS-MAP.md) |
| Find exact tools/chart versions | [Stack and versions](docs/STACK-AND-VERSIONS.md) |

## Delivery and verification

Application/Helm/CI pull requests run validation and, when applicable, Trivy scans. Docs-only changes do not trigger this workflow. Independent Git tags such as `backend-v0.1.0` and `frontend-v0.1.0` publish images to GHCR, update `helm/platformlab/values.yaml`, and allow Argo CD to roll out the selected service. Both `v0.1.0` images were verified running with Argo CD `Synced / Healthy` on 13 October 2026.

The CI workflow renders **and packages** the Helm chart during validation; the app chart is kept in Git rather than published to a chart registry. See [CI/CD flow](docs/CI-CD-AND-DEVELOPMENT-FLOW.md) for the details.

**Scope:** this is a Minikube assignment, not a claim of production HA. The full lab uses local CSI HostPath storage; production would need managed storage, external TLS, stronger access controls and backup/recovery planning.
