#!/usr/bin/env bash
# PlatformLab local platform lifecycle helper (Windows Git Bash, Linux and macOS).
# Commands: check, verify, start, bootstrap, storage, doctor, flow, uis, stop.
# Startup gates verify dependencies; existing Pods still restart in parallel.
# Never deletes PVCs, forcibly changes HPA replicas, or syncs Argo CD.
set -Eeuo pipefail

PROFILE="${PLATFORMLAB_PROFILE:-platformlab}"
CONTEXT="${PLATFORMLAB_CONTEXT:-platformlab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UI_HELPER="$SCRIPT_DIR/platformlab-uis.sh"
STORAGE_HELPER="$SCRIPT_DIR/platformlab-storage.sh"
NODE_BOOTSTRAP="$REPO_ROOT/platform/bootstrap/label-workers.sh"
OPS_DIR="${PLATFORMLAB_OPS_DIR:-$HOME/.platformlab-ops}"
ROLLOUT_TIMEOUT="${PLATFORMLAB_ROLLOUT_TIMEOUT:-240}"
ARGO_TIMEOUT="${PLATFORMLAB_ARGO_TIMEOUT:-180}"
# Fail early for invalid operator-provided timeout overrides.
for timeout in "$ROLLOUT_TIMEOUT" "$ARGO_TIMEOUT"; do
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || {
    printf '[ERROR] Timeouts must be positive whole seconds.\n' >&2
    exit 2
  }
done

section() { printf '\n%s\n' "==== $* ===="; }
ok()      { printf '[OK] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*"; }
info()    { printf '[INFO] %s\n' "$*"; }
fail()    { printf '[ERROR] %s\n' "$*" >&2; }
has()     { command -v "$1" >/dev/null 2>&1; }
k()       { kubectl --context "$CONTEXT" --request-timeout=10s "$@"; }

# Windows Git Bash/MSYS may rewrite /readyz into a Windows filesystem path.
# Disable that conversion ONLY for the raw Kubernetes API request. On Linux
# and macOS, kubectl runs normally; other kubectl file paths remain untouched.
kube_api_ready() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) MSYS_NO_PATHCONV=1 k get --raw=/readyz ;;
    *)                    k get --raw=/readyz ;;
  esac
}

# Watch operations must not inherit the short API request timeout.
kw()      { kubectl --context "$CONTEXT" "$@"; }

usage() {
  cat <<'USAGE'
PlatformLab - local Kubernetes platform (Windows Git Bash / Linux / macOS)

  bash scripts/platformlab-env.sh check       Read-only health, statistics and next steps
  bash scripts/platformlab-env.sh start       Start EXISTING 3-node cluster, align CSI storage and verify
  bash scripts/platformlab-env.sh verify      Read-only readiness checks; do not change addons
  bash scripts/platformlab-env.sh bootstrap   Start, restore worker labels, verify and report GitOps
  bash scripts/platformlab-env.sh storage status    Check CSI addon and storage ownership
  bash scripts/platformlab-env.sh storage reconcile Align CSI addon during maintenance
  bash scripts/platformlab-env.sh doctor      Extended read-only diagnostics (events, allocations)
  bash scripts/platformlab-env.sh flow        Show ordered daily bootstrap and shutdown flow
  bash scripts/platformlab-env.sh uis start   Delegate to platformlab-uis.sh start|open|status|stop|logs
  bash scripts/platformlab-env.sh stop        Snapshot state, stop UI forwards and Minikube (no delete)

Startup gates check readiness in dependency order. On start, storage reconcile
aligns Minikube CSI addon state after checking PVC ownership. Verify is read-only.
No app YAML is applied or pruned; HPAs, Argo CD sync and PVCs remain untouched.
USAGE
}

# Query only. Stopped Minikube profiles can return a non-zero exit code, so
# we also inspect the text while reporting status.
minikube_state() {
  minikube -p "$PROFILE" status 2>&1 || true
}

minikube_profile_exists() {
  local profiles
  profiles="$(minikube profile list --output=json 2>/dev/null || true)"
  [[ -n "$profiles" ]] && printf '%s\n' "$profiles" | grep -Eq '"Name"[[:space:]]*:[[:space:]]*"'"$PROFILE"'"'
}

docker_healthy() {
  has docker && docker info >/dev/null 2>&1
}

kube_healthy() {
  has kubectl && kube_api_ready >/dev/null 2>&1
}

# Fail visibly instead of reporting success before the API is usable.
wait_for_api() {
  local deadline=$((SECONDS + 180)) next_notice=$((SECONDS + 20))
  info "Waiting for Kubernetes API /readyz (context: $CONTEXT, timeout: 180s)..."
  until kube_healthy; do
    if (( SECONDS >= deadline )); then
      fail "Kubernetes API did not become ready (context: $CONTEXT)."
      return 1
    fi
    if (( SECONDS >= next_notice )); then
      info 'Kubernetes API is still starting; retrying...'
      next_notice=$((SECONDS + 20))
    fi
    sleep 5
  done
  ok 'Kubernetes API is ready.'
}

# Deployments, StatefulSets and DaemonSets are watched through their controllers.
# Missing resources are errors in the existing full-lab profile, not silent skips.
wait_for_rollout() {
  local namespace="$1" resource="$2"
  if ! k -n "$namespace" get "$resource" >/dev/null 2>&1; then
    fail "Missing $namespace/$resource. Check installation and GitOps first."
    return 1
  fi
  info "Waiting for $namespace/$resource (up to ${ROLLOUT_TIMEOUT}s)..."
  if ! kw -n "$namespace" rollout status "$resource" --timeout="${ROLLOUT_TIMEOUT}s"; then
    fail "Readiness gate failed: $namespace/$resource."
    return 1
  fi
}

# Verify PVC binding rather than deleting or recreating volumes during recovery.
verify_monitoring_volumes() {
  local pvc_status
  pvc_status="$(k -n monitoring get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null)" || {
    fail 'Cannot read monitoring PVCs.'
    return 1
  }
  if [[ -z "$pvc_status" ]]; then
    fail 'No monitoring PVCs found; inspect Prometheus/Alertmanager storage.'
    return 1
  fi
  local name phase
  while IFS='|' read -r name phase; do
    [[ -n "$name" ]] || continue
    if [[ "$phase" != Bound ]]; then
      fail "Monitoring PVC $name is $phase (expected Bound)."
      return 1
    fi
    ok "Monitoring PVC $name is Bound."
  done <<< "$pvc_status"
}

# Metrics Server must publish a working API, not just a Ready Deployment.
wait_for_metrics_api() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT)) api
  while :; do
    api="$(k get apiservice v1beta1.metrics.k8s.io -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null || true)"
    if [[ "$api" == True ]]; then
      ok 'Metrics API is available.'
      return 0
    fi
    if (( SECONDS >= deadline )); then
      fail "Metrics API is not available (status: ${api:-unknown})."
      return 1
    fi
    sleep 5
  done
}

# Argo CD is allowed to reconcile normally; verify status without forcing Sync.
wait_for_gitops() {
  local deadline=$((SECONDS + ARGO_TIMEOUT))
  local statuses found bad
  local -a expected=(platformlab-root platformlab platformlab-secrets platformlab-metrics-server \
    platformlab-monitoring platformlab-storage sealed-secrets-controller)
  while :; do
    statuses="$(k -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
    found=0
    bad=0
    local app line
    for app in "${expected[@]}"; do
      line="$(printf '%s\n' "$statuses" | awk -F '|' -v a="$app" '$1==a {print $2 "|" $3; exit}')"
      if [[ "$line" == 'Synced|Healthy' ]]; then
        found=$((found + 1))
      else
        bad=$((bad + 1))
      fi
    done
    if (( bad == 0 )); then
      ok "Argo CD: ${found}/${#expected[@]} Applications are Synced / Healthy."
      return 0
    fi
    if (( SECONDS >= deadline )); then
      fail "Argo CD is not fully healthy: ${found}/${#expected[@]} Synced / Healthy."
      k -n argocd get applications || true
      return 1
    fi
    sleep 5
  done
}

# These are readiness gates, not an attempt to order kubelet container startup.
verify_platform() {
  section 'Stage 1/6 | API and node readiness'
  wait_for_api
  kw wait --for=condition=Ready "node/$PROFILE" "node/${PROFILE}-m02" "node/${PROFILE}-m03" --timeout="${ROLLOUT_TIMEOUT}s"

  section 'Stage 2/6 | Kubernetes networking and storage'
  wait_for_rollout kube-system daemonset/calico-node
  wait_for_rollout kube-system deployment/coredns
  wait_for_rollout kube-system daemonset/kube-proxy
  wait_for_rollout kube-system daemonset/csi-hostpathplugin
  info 'Verifying one active storage provisioner and GitOps PVC ownership'
  bash "$STORAGE_HELPER" status --profile "$PROFILE" --context "$CONTEXT"

  section 'Stage 3/6 | Ingress and platform controllers'
  wait_for_rollout traefik deployment/traefik
  wait_for_rollout sealed-secrets deployment/sealed-secrets-controller
  wait_for_rollout argocd statefulset/argocd-application-controller
  wait_for_rollout argocd deployment/argocd-repo-server
  wait_for_rollout argocd deployment/argocd-server

  section 'Stage 4/6 | Monitoring and Metrics API'
  wait_for_rollout monitoring deployment/platformlab-monitoring-kube-pr-operator
  wait_for_rollout monitoring statefulset/prometheus-platformlab-monitoring-kube-pr-prometheus
  wait_for_rollout monitoring statefulset/alertmanager-platformlab-monitoring-kube-pr-alertmanager
  wait_for_rollout kube-system deployment/platformlab-metrics-server
  wait_for_metrics_api
  verify_monitoring_volumes

  section 'Stage 5/6 | Application workloads'
  wait_for_rollout platformlab-app deployment/platformlab-backend
  wait_for_rollout platformlab-app deployment/platformlab-frontend

  section 'Stage 6/6 | GitOps reconciliation status'
  wait_for_gitops
  ok 'All full-lab readiness gates passed.'
}

# Snapshot resources for later comparisons; never patch restart counters.
snapshot_pods() {
  if ! kube_healthy; then
    warn 'Pod snapshot skipped: Kubernetes API unavailable.'
    return 0
  fi
  mkdir -p "$OPS_DIR"
  local path="$OPS_DIR/pods-$(date '+%Y%m%d-%H%M%S').json"
  if k get pods -A -o json > "$path"; then
    info "Pod snapshot saved: $path"
  else
    rm -f -- "$path"
    warn 'Pod snapshot failed; continuing without a snapshot.'
  fi
}

show_nodes_and_slots() {
  section 'Kubernetes nodes and workload placement'
  k get nodes -L workload-tier,platformlab.io/pool || return 0

  local nodes pods node maximum used phase
  nodes="$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.allocatable.pods}{"\n"}{end}' 2>/dev/null || true)"
  pods="$(k get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$nodes" ]]; then
    printf '\n%-17s %8s %8s %8s\n' 'NODE' 'PODS' 'MAX' 'SLOTS'
    while IFS='|' read -r node maximum; do
      [[ -n "$node" && "$maximum" =~ ^[0-9]+$ ]] || continue
      used="$(printf '%s\n' "$pods" | awk -F '|' -v n="$node" '$1==n && $2!="Succeeded" && $2!="Failed" {count++} END {print count+0}')"
      printf '%-17s %8d %8d %8d\n' "$node" "$used" "$maximum" "$(( maximum-used ))"
    done <<< "$nodes"
    info 'SLOTS count pods, not free CPU/RAM. See Docker stats and pod requests.'
  fi
}

show_docker() {
  section 'Docker runtime'
  if ! has docker; then
    warn 'Docker CLI not found. Install Docker or make it available in PATH.'
    return 1
  fi
  if ! docker_healthy; then
    warn 'Docker daemon unavailable. Start Docker Desktop or Docker Engine and retry.'
    info 'Then run: bash scripts/platformlab-env.sh start'
    return 1
  fi
  ok 'Docker daemon ready.'
  local di
  di="$(docker info --format 'CPU={{.NCPU}}  DockerRAMbytes={{.MemTotal}}' 2>/dev/null || true)"
  [[ -n "$di" ]] && printf '%s\n' "$di"
  printf '\n%-16s %-24s\n' 'NODE' 'ACTUAL MEMORY / LIMIT'
  docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' \
    "$PROFILE" "${PROFILE}-m02" "${PROFILE}-m03" 2>/dev/null \
    | while IFS='|' read -r name mem cpu; do
        [[ -n "$name" ]] && printf '%-16s %-24s CPU %s\n' "$name" "$mem" "$cpu"
      done || true
  info 'Docker limits differ from Kubernetes requests/limits.'
}

show_cluster() {
  section 'Minikube profile'
  if ! has minikube; then
    warn 'Minikube not found.'
    return 1
  fi
  local state
  state="$(minikube_state)"
  printf '%s\n' "$state"
  if [[ "$state" == *'host: Stopped'* ]]; then
    warn "Profile '$PROFILE' is stopped. Run: bash scripts/platformlab-env.sh start"
    return 1
  fi
  if ! kube_healthy; then
    warn "Kubernetes API is not ready for context '$CONTEXT'."
    info 'After startup, wait 1-3 minutes and rerun check.'
    return 1
  fi
  ok "API Server ready (context '$CONTEXT')."
  return 0
}

show_argo() {
  section 'GitOps - Argo CD'
  if ! k get ns argocd >/dev/null 2>&1; then
    warn 'Argo CD namespace missing. Initial Argo CD setup required.'
    return 0
  fi
  k -n argocd get applications || true
  local app sync health
  for app in platformlab-root platformlab platformlab-metrics-server platformlab-monitoring platformlab-storage platformlab-secrets sealed-secrets-controller; do
    sync="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(k -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ -z "$sync" ]]; then
      warn "Argo CD Application '$app' is missing."
    elif [[ "$sync" != Synced ]]; then
      warn "$app: $sync / ${health:-unknown}; review Diff and Sync if needed."
    elif [[ "$health" == Degraded || "$health" == Missing ]]; then
      warn "$app: Synced / $health; check Argo CD details."
    elif [[ "$health" == Progressing && "$app" == platformlab ]]; then
      info 'platformlab: Progressing may be caused by Ingress status; check Pods and Services.'
    fi
  done
  if ! k -n argocd get application platformlab-root >/dev/null 2>&1; then
    info 'Root bootstrap (only after Argo CD installation):'
    info "  kubectl --context $CONTEXT apply -f gitops/bootstrap/platformlab-root.yaml"
  fi
}

show_runtime() {
  section 'Application / HPA / placement'
  k -n platformlab-app get deploy,pods,hpa -o wide 2>/dev/null || warn 'Application resources unavailable.'
  section 'Monitoring / PVC / storage'
  k -n monitoring get pods,pvc -o wide 2>/dev/null || warn 'Monitoring resources unavailable.'
  local binding
  binding="$(k get storageclass platformlab-csi-wffc -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)"
  if [[ "$binding" == WaitForFirstConsumer ]]; then
    ok 'StorageClass platformlab-csi-wffc = WaitForFirstConsumer.'
  else
    warn "StorageClass platformlab-csi-wffc: ${binding:-missing} (expected WaitForFirstConsumer)."
  fi
}

show_metrics() {
  section 'Utilization - Metrics Server'
  local api
  api="$(k get apiservice v1beta1.metrics.k8s.io -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' 2>/dev/null || true)"
  if [[ "$api" == True ]]; then
    ok 'Metrics API Available=True'
    k top nodes 2>/dev/null || warn 'Metrics API ready; waiting for samples.'
    k -n platformlab-app top pods 2>/dev/null || true
  else
    warn "Metrics API: ${api:-missing}; HPA needs Metrics Server."
    info 'Argo CD: platformlab-root -> Refresh/Sync -> platformlab-metrics-server.'
  fi
}

show_local() {
  section 'Local helper and Git'
  if [[ -f "$UI_HELPER" ]]; then
    bash "$UI_HELPER" status || true
    info 'Web UI: bash scripts/platformlab-env.sh uis start'
    info 'Open:   bash scripts/platformlab-env.sh uis open'
  else
    info 'UI helper missing: scripts/platformlab-uis.sh'
  fi
  if has git && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Branch: %s\n' "$(git -C "$REPO_ROOT" branch --show-current)"
    info 'Modified files:'
    git -C "$REPO_ROOT" status --short || true
  fi
}

show_next() {
  section 'NEXT - daily bootstrap flow'
  printf '%s\n' \
    '1. Start Docker Desktop (Windows/macOS) or Docker Engine (Linux).' \
    '2. Start (restores labels and checks readiness): bash scripts/platformlab-env.sh start' \
    '3. Recheck without restarting: bash scripts/platformlab-env.sh verify' \
    '4. If Argo root is OutOfSync: review Diff and Sync (no Force/Prune).' \
    '5. For app OutOfSync: review Argo CD Diff; sync if needed.' \
    '6. UI: bash scripts/platformlab-env.sh uis start && bash scripts/platformlab-env.sh uis open' \
    '7. Stop: bash scripts/platformlab-env.sh stop (keeps cluster/PVC).' \
    '8. Storage ownership: bash scripts/platformlab-env.sh storage status' \
    '9. Runbook: docs/OPERATIONS-LIFECYCLE.md'
}

check() {
  printf '\nPLATFORMLAB | Environment check | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  if ! show_docker; then show_next; return 0; fi
  if ! show_cluster; then show_local; show_next; return 0; fi
  show_nodes_and_slots
  show_argo
  show_runtime
  show_metrics
  show_local
  show_next
}

start_cluster() {
  section 'Start EXISTING PlatformLab cluster'
  has minikube || { fail 'Minikube not found in PATH'; return 1; }
  has kubectl || { fail 'kubectl not found in PATH'; return 1; }
  docker_healthy || {
    fail 'Docker daemon is not ready. Start Docker Desktop or Docker Engine and retry.'
    return 1
  }
  if ! minikube_profile_exists; then
    fail "Minikube profile '$PROFILE' was not found. Refusing to create a new cluster."
    info 'To create a NEW cluster intentionally, use the separately documented installation procedure.'
    return 1
  fi
  minikube -p "$PROFILE" start
  wait_for_api
  kw wait --for=condition=Ready "node/$PROFILE" "node/${PROFILE}-m02" "node/${PROFILE}-m03" --timeout="${ROLLOUT_TIMEOUT}s"
  restore_worker_labels
  # Minikube may report CSI as disabled after restoring its existing Pods.
  # Align the addon before Stage 2's strict, read-only storage check.
  # The helper first checks PVC ownership and never deletes PVCs or PVs.
  section 'Storage | Align CSI addon after Minikube start'
  bash "$STORAGE_HELPER" reconcile --profile "$PROFILE" --context "$CONTEXT"
  verify_platform
  snapshot_pods
  ok 'Three nodes and all installed platform components are ready.'
}

restore_worker_labels() {
  section 'Restoring worker labels (idempotent)'
  if [[ ! -f "$NODE_BOOTSTRAP" ]]; then
    fail 'Missing platform/bootstrap/label-workers.sh; cannot restore scheduling labels.'
    return 1
  fi
  local active
  active="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$active" != "$CONTEXT" ]]; then
    fail "Worker label helper requires active context '$CONTEXT' (current: '$active')."
    info "Run: kubectl config use-context $CONTEXT"
    return 1
  fi
  bash "$NODE_BOOTSTRAP"
}

bootstrap() {
  start_cluster
  check
  info 'Worker labels restored. No forced GitOps sync or resource deletion was performed.'
}

doctor() {
  check
  if ! kube_healthy; then return 0; fi
  section 'Doctor - node allocation'
  for node in "$PROFILE" "${PROFILE}-m02" "${PROFILE}-m03"; do
    printf '\n%s\n' "--- $node ---"
    k describe node "$node" 2>/dev/null | sed -n '/Allocated resources:/,+8p' || true
  done
  section 'Doctor - recent namespace events'
  for ns in platformlab-app monitoring kube-system argocd; do
    printf '\n%s\n' "--- $ns ---"
    k -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 12 || true
  done
  section 'Doctor - Docker memory limits (bytes)'
  docker inspect "$PROFILE" "${PROFILE}-m02" "${PROFILE}-m03" \
    --format '{{.Name}} RAM={{.HostConfig.Memory}} SWAP={{.HostConfig.MemorySwap}}' 2>/dev/null || true
}

stop_cluster() {
  section 'Safe shutdown (no delete, no PVC cleanup)'
  if [[ -f "$UI_HELPER" ]]; then
    bash "$UI_HELPER" stop || warn 'UI forwards could not all be stopped.'
  fi
  if ! has minikube; then fail 'Minikube not found.'; return 1; fi
  if ! minikube_profile_exists; then fail "Profile '$PROFILE' does not exist."; return 1; fi
  snapshot_pods
  info 'No Deployment, HPA, Argo CD Application, Secret or PVC is modified.'
  minikube -p "$PROFILE" stop
  ok 'Minikube stopped. Git repo, images, cluster and PVC resources were not deleted.'
}

flow() {
  cat <<'FLOW'

PLATFORMLAB - Recommended daily operations (Windows Git Bash / Linux / macOS)

  Start Docker Desktop or Docker Engine (full lab needs more RAM than demo).
  bash scripts/platformlab-env.sh check
  bash scripts/platformlab-env.sh start
  # The EXISTING cluster starts, restores node labels, then checks readiness.
  bash scripts/platformlab-env.sh verify
  # Existing Kubernetes Pods still restart in parallel at node startup.
  # If Argo CD is OutOfSync, review Diff and the configured sync policy.
  bash scripts/platformlab-env.sh uis start
  bash scripts/platformlab-env.sh uis open
  bash scripts/platformlab-env.sh check
  # Develop: Git commit/push -> Argo CD reconciliation -> smoke tests.
  bash scripts/platformlab-env.sh stop

SAFETY: no minikube delete; no PVC deletion; no scaling managed resources;
        no automatic Argo prune/force/sync; no secrets printed.
FLOW
}

case "${1:-check}" in
  check|status) check ;;
  start) start_cluster; check ;;
  verify) verify_platform ;;
  bootstrap) bootstrap ;;
  doctor) doctor ;;
  flow) flow ;;
  uis)
    shift
    [[ -f "$UI_HELPER" ]] || { fail 'Missing scripts/platformlab-uis.sh'; exit 1; }
    if (( $# == 0 )); then set -- status; fi
    bash "$UI_HELPER" "$@" ;;
  storage)
    shift
    [[ -f "$STORAGE_HELPER" ]] || { fail 'Missing scripts/platformlab-storage.sh'; exit 1; }
    bash "$STORAGE_HELPER" "${1:-status}" --profile "$PROFILE" --context "$CONTEXT" "${@:2}" ;;
  stop) stop_cluster ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
