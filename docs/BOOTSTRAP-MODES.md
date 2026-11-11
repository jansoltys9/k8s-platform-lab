# First-time setup (for reviewers)

Use **demo** for a quick, reproducible assessment. Use **full** only if you want to set up Argo CD, monitoring and the three-node environment from scratch.

### Before you start

Install Docker Desktop (Linux containers), Git, Git Bash, Minikube, kubectl, Helm and OpenSSL. You need internet access for the first setup. The demo checks available Docker memory and needs at least **4 GiB**; the full lab needs around **8 GiB or more**.

```bash
git clone https://github.com/jansoltys9/k8s-platform-lab.git
cd k8s-platform-lab
docker info
```

## Option 1 – Quick reviewer demo (one node)

**Step 1: cluster, Calico and Traefik.** Nothing from the app is installed yet.

```bash
bash scripts/platformlab-bootstrap.sh --mode demo --phase infra
```

**Step 2: install the application and Metrics Server.** The script creates a *local* demo Secret; no access to the author's credentials is needed.

```bash
bash scripts/platformlab-bootstrap.sh --mode demo --phase app
kubectl --context platformlab-review -n platformlab-app get pods,deploy,hpa
```

**Step 3: open the application.** Keep this terminal running:

```bash
kubectl --context platformlab-review -n traefik port-forward svc/traefik 18082:80
```

Open <http://127.0.0.1:18082/> and test <http://127.0.0.1:18082/api/hello>. Both should respond. Use `Ctrl+C` to stop the forward.

**Stop without deleting anything:**

```bash
minikube stop -p platformlab-review
```

This quick demo does **not** include Argo CD, Prometheus or a highly available cluster. It is the easiest reviewer starting point.

## Option 2 – Full GitOps lab (advanced, three nodes)

This takes more time and is **not** a one-command fresh install. Stop the demo if your laptop has limited resources.

```bash
bash scripts/platformlab-bootstrap.sh --mode full --phase infra
bash scripts/platformlab-bootstrap.sh --mode full --phase gitops
```

The second command gives *guided* Argo CD setup; it does not automatically install/sync every child Application. Before syncing the full app:

1. Install/configure Argo CD and apply the management AppProject, then `gitops/bootstrap/platformlab-root.yaml` as guided by the bootstrap script.
2. If using a fork, update `repoURL` **and AppProject source-repository permissions** to your own repository.
3. Install/sync the Sealed Secrets controller and [seal a new Secret for your cluster](FULL-LAB-SECRETS.md). The author's encrypted Secret will **not** work in a new cluster.
4. Sync the platform Applications, then the app. Check `kubectl -n argocd get applications` and `kubectl -n monitoring get pods,pvc`.

For daily use of a full lab that is **already installed**, switch to [Daily use](OPERATIONS-LIFECYCLE.md). Do not rerun first-install phases every morning.
