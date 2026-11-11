#!/usr/bin/env bash
# Initial environment setup only. App image builds/releases belong to CI/CD.
# Keep daily checks and UI port-forwards in platformlab-env.sh / platformlab-uis.sh.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""
PHASE=""
K8S_VERSION="v1.35.1"
TRAEFIK_CHART_VERSION="41.6.1"
if [[ -r "$ROOT/platform/argocd/CHART_VERSION" ]]; then
  ARGOCD_CHART_VERSION="$(tr -d '\r\n' < "$ROOT/platform/argocd/CHART_VERSION")"
fi
[[ -n "${ARGOCD_CHART_VERSION:-}" ]] || ARGOCD_CHART_VERSION="10.10.1"

usage() {
  cat <<'HELP'
PlatformLab bootstrap (Windows Git Bash / Linux / macOS)

  bash scripts/platformlab-bootstrap.sh --mode demo --phase infra
  bash scripts/platformlab-bootstrap.sh --mode demo --phase app

  bash scripts/platformlab-bootstrap.sh --mode full --phase infra
  bash scripts/platformlab-bootstrap.sh --mode full --phase gitops

Phases are intentional; there is NO 'all' command.
  demo/infra   One Minikube node + Calico + Traefik (no app yet)
  demo/app     Metrics Server + local demo Secret + Helm application
  full/infra   Three nodes + Calico + CSI HostPath + Traefik (no app yet)
  full/gitops  Guide Argo CD + App-of-Apps bootstrap (no auto-sync)

Daily operations (for the EXISTING full lab):
  scripts/platformlab-env.sh     Daily check / restart / stop (full lab)
  scripts/platformlab-uis.sh     Local web UI port-forwards
  scripts/platformlab-storage.sh Full-lab CSI addon status and explicit reconcile

After setup, use: bash scripts/platformlab-env.sh check
For a fully installed existing lab, run: bash scripts/platformlab-env.sh verify
Note: this bootstrap is for FIRST-TIME installation, not daily power cycles.
      The reviewer demo is standalone and does not require Argo CD.

Container images are built, scanned and published by the CI workflow,
not by this bootstrap. No command deletes profiles, PVCs or Secrets.
HELP
}

while (( $# )); do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || { echo 'ERROR: --mode requires a value' >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --phase) [[ $# -ge 2 ]] || { echo 'ERROR: --phase requires a value' >&2; exit 2; }; PHASE="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE:$PHASE" in
  demo:infra|demo:app|full:infra|full:gitops) ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$MODE" == demo ]]; then PROFILE="platformlab-review"; else PROFILE="platformlab"; fi
has() { command -v "$1" >/dev/null 2>&1; }
log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
require() { for x in "$@"; do has "$x" || { err "Missing CLI: $x"; exit 1; }; done; }
k() { kubectl --context "$PROFILE" "$@"; }

# Only Windows Git Bash/MSYS needs protection against /readyz path conversion.
# Use the ordinary kubectl command on Linux and macOS.
kube_api_ready() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) MSYS_NO_PATHCONV=1 k --request-timeout=10s get --raw=/readyz ;;
    *)                    k --request-timeout=10s get --raw=/readyz ;;
  esac
}

wait_for_api() {
  local deadline=$((SECONDS + 180)) next_notice=$((SECONDS + 20))
  log "Waiting for Kubernetes API /readyz (context: $PROFILE, timeout: 180s)..."
  until kube_api_ready >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      err "Kubernetes API did not become ready for context '$PROFILE'."
      return 1
    fi
    if (( SECONDS >= next_notice )); then
      log 'Kubernetes API is still starting; retrying...'
      next_notice=$((SECONDS + 20))
    fi
    sleep 5
  done
  log 'Kubernetes API is ready.'
}

profile_exists() {
  minikube profile list --output=json 2>/dev/null \
    | grep -Eq '"Name"[[:space:]]*:[[:space:]]*"'"$PROFILE"'"'
}
docker_memory_mib() {
  local bytes
  bytes="$(docker info --format '{{.MemTotal}}')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || { err 'Cannot read Docker memory'; exit 1; }
  printf '%s\n' "$((bytes / 1024 / 1024))"
}
assert_context() {
  [[ "$(kubectl config current-context)" == "$PROFILE" ]] || {
    err "Wrong Kubernetes context. Expected: $PROFILE"; exit 1;
  }
}

infra() {
  require docker minikube kubectl helm
  docker info >/dev/null 2>&1 || { err 'Docker daemon unavailable. Start Docker Desktop or Docker Engine.'; exit 1; }
  [[ -f "$ROOT/platform/traefik/values-minikube.yaml" ]] || { err 'Traefik values not found'; exit 1; }

  local available memory cpus current_nodes
  available="$(docker_memory_mib)"
  if profile_exists; then
    log "Starting existing profile: $PROFILE (preserving its settings)"
    minikube -p "$PROFILE" start
  elif [[ "$MODE" == demo ]]; then
    if (( available >= 7168 )); then memory=6000
    elif (( available >= 5120 )); then memory=4000
    elif (( available >= 4096 )); then memory=3000
    else err "Docker has $available MiB; demo needs >=4096 MiB"; exit 1
    fi
    cpus=2
    log "Creating demo: one node, ${memory}MiB, ${cpus} CPUs; Docker available: ${available}MiB"
    minikube start -p "$PROFILE" --driver=docker --kubernetes-version="$K8S_VERSION" \
      --cpus="$cpus" --memory="${memory}m" --cni=calico
  else
    if (( available < 8192 )); then
      err "Full three-node lab needs about 8GiB Docker RAM (available: ${available}MiB)."
      err 'Use demo mode or increase Docker/WSL memory before creating the full lab.'
      exit 1
    fi
    log 'Creating full lab control plane; workers will be added separately.'
    minikube start -p "$PROFILE" --driver=docker --kubernetes-version="$K8S_VERSION" \
      --cpus=4 --memory=3500m --cni=calico
  fi
  kubectl config use-context "$PROFILE" >/dev/null
  assert_context
  wait_for_api

  if [[ "$MODE" == full ]]; then
    current_nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
    while (( current_nodes < 3 )); do
      log "Adding worker ${current_nodes}/2 to $PROFILE"
      minikube node add -p "$PROFILE" --worker
      current_nodes=$((current_nodes + 1))
    done
    # Labels are reproducible and do not force workloads to move immediately.
    k wait --for=condition=Ready node/platformlab-m02 --timeout=180s
    k wait --for=condition=Ready node/platformlab-m03 --timeout=180s
    k label node platformlab-m02 workload-tier=apps platformlab.io/pool=workers --overwrite
    k label node platformlab-m03 workload-tier=monitoring platformlab.io/pool=workers --overwrite
  else
    k wait --for=condition=Ready node/platformlab-review --timeout=180s
    k label node platformlab-review workload-tier=apps platformlab.io/pool=workers --overwrite
  fi

  # CoreDNS and Calico must be ready before deploying ingress.
  log 'Waiting for Kubernetes DNS and Calico networking'
  k -n kube-system rollout status deployment/coredns --timeout=180s
  k -n kube-system rollout status daemonset/calico-node --timeout=180s

  # Full lab storage is an infrastructure prerequisite. Keep ONE active driver:
  # csi-hostpath-driver; GitOps manages the platformlab-csi-wffc StorageClass.
  # The demo profile is isolated and does not use monitoring CSI PVCs.
  if [[ "$MODE" == full ]]; then
    log 'Aligning CSI HostPath storage before GitOps or monitoring deployment'
    bash "$ROOT/scripts/platformlab-storage.sh" reconcile --profile "$PROFILE" --context "$PROFILE"
  fi

  # Traefik is the only manually installed ingress prerequisite.
  log 'Installing/updating Traefik (infrastructure prerequisite)'
  helm repo add traefik https://traefik.github.io/charts --force-update
  helm upgrade --install traefik traefik/traefik --kube-context "$PROFILE" --version "$TRAEFIK_CHART_VERSION" \
    -n traefik --create-namespace -f "$ROOT/platform/traefik/values-minikube.yaml" \
    --wait --timeout 5m
  k get nodes -L workload-tier,platformlab.io/pool
  log 'Infrastructure ready. No application or monitoring add-ons were installed.'
  if [[ "$MODE" == demo ]]; then
    log 'Next: bash scripts/platformlab-bootstrap.sh --mode demo --phase app'
  else
    log 'Next: bash scripts/platformlab-bootstrap.sh --mode full --phase gitops'
  fi
}

demo_app() {
  require docker kubectl helm openssl tr mktemp
  docker info >/dev/null 2>&1 || { err 'Docker daemon unavailable. Start Docker Desktop or Docker Engine.'; exit 1; }
  wait_for_api
  k get node platformlab-review >/dev/null 2>&1 || {
    err 'Demo profile missing. Run --mode demo --phase infra first.'; exit 1;
  }
  k -n traefik get svc traefik >/dev/null 2>&1 || {
    err 'Traefik missing. Run the infra phase first.'; exit 1;
  }
  [[ -f "$ROOT/helm/platformlab/Chart.yaml" ]] || { err 'Helm chart not found'; exit 1; }
  assert_context
  log 'Installing Metrics Server for HPA (demo only)'
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
  helm upgrade --install platformlab-metrics-server metrics-server/metrics-server --kube-context "$PROFILE" \
    --version 3.14.0 -n kube-system --set 'args[0]=--kubelet-insecure-tls' \
    --wait --timeout 5m

  k create namespace platformlab-app --dry-run=client -o yaml | k apply -f -
  if ! k -n platformlab-app get secret platformlab-backend-auth-review >/dev/null 2>&1; then
    log 'Generating a new demo-only authentication token'
    umask 077
    token_file="$(mktemp)"
    trap 'rm -f -- "$token_file"' EXIT
    openssl rand -hex 32 | tr -d '\r\n' > "$token_file"
    [[ "$(wc -c < "$token_file" | tr -d ' ')" == 64 ]] || { err 'Invalid token length'; exit 1; }
    k -n platformlab-app create secret generic platformlab-backend-auth-review \
      --from-file="INTERNAL_API_TOKEN=$token_file" --dry-run=client -o yaml | k apply -f - >/dev/null
    rm -f -- "$token_file"
    trap - EXIT
  else
    log 'Reusing the existing demo Secret (not rotating it)'
  fi
  log 'Installing application via Helm; observability CRDs disabled for demo'
  helm lint "$ROOT/helm/platformlab" --set observability.enabled=false
  helm upgrade --install platformlab "$ROOT/helm/platformlab" --kube-context "$PROFILE" -n platformlab-app \
    --set observability.enabled=false \
    --set backend.auth.existingSecretName=platformlab-backend-auth-review \
    --wait --timeout 5m
  log 'Checking backend and frontend rollout readiness'
  k -n platformlab-app rollout status deployment/platformlab-backend --timeout=180s
  k -n platformlab-app rollout status deployment/platformlab-frontend --timeout=180s
  k -n platformlab-app get deploy,pods,hpa -o wide
  log 'UI: kubectl --context platformlab-review -n traefik port-forward svc/traefik 18082:80'
  log 'Then open http://127.0.0.1:18082/ and /api/hello'
}

full_gitops() {
  require kubectl helm
  wait_for_api
  k get nodes >/dev/null 2>&1 || { err 'Start the full infrastructure first.'; exit 1; }
  # Fail before GitOps if the CSI infrastructure addon has not been enabled.
  bash "$ROOT/scripts/platformlab-storage.sh" status --profile "$PROFILE" --context "$PROFILE"
  log 'The full lab uses Argo CD to deploy the application and add-ons.'
  if ! k -n argocd get deployment argocd-server >/dev/null 2>&1; then
    echo 'Argo CD is not installed. Install it once from a pinned Helm chart:'
    echo '  helm repo add argo https://argoproj.github.io/argo-helm'
    echo '  # Chart version is pinned in platform/argocd/CHART_VERSION.'
    echo '  helm upgrade --install argocd argo/argo-cd --kube-context platformlab -n argocd --create-namespace \'
    echo "    -f platform/argocd/values-minikube.yaml --version $ARGOCD_CHART_VERSION"
    echo 'Then rerun this phase. Argo CD itself needs an initial installation.'
    return 1
  fi
  log 'Argo CD is present; no sync was triggered.'
  k -n argocd get applications || true
  echo 'GitOps demo sequence (run each step manually):'
  echo '  1. kubectl --context platformlab apply -f gitops/apps/project-platformlab-management.yaml'
  echo '  2. kubectl --context platformlab apply -f gitops/bootstrap/platformlab-root.yaml'
  echo '  3. In Argo CD: Sync platformlab-root, then verify platform add-ons and storage.'
  echo '  4. On a NEW cluster, create your own SealedSecret (docs/FULL-LAB-SECRETS.md).'
  echo '  5. Verify the Secret is present before syncing the application.'
  echo '  6. In Argo CD: Sync platformlab; wait for both Deployments to be Ready.'
  echo 'No app/add-on was automatically installed or synchronized by this command.'
}

case "$PHASE" in
  infra) infra ;;
  app) demo_app ;;
  gitops) full_gitops ;;
esac
