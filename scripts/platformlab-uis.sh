#!/usr/bin/env bash
# Local UI access for the PlatformLab Minikube lab (Windows Git Bash / Linux / macOS).
# Usage: bash scripts/platformlab-uis.sh start|status|open|stop|logs
set -Eeuo pipefail

CONTEXT="${PLATFORMLAB_CONTEXT:-platformlab}"
umask 077
STATE_DIR="${HOME:-${TMPDIR:-/tmp}}/.cache/platformlab-ui-forwards"
mkdir -p "$STATE_DIR"

names=(app argocd prometheus alertmanager)

url_for() {
  case "$1" in
    app)          printf '%s\n' 'http://127.0.0.1:18080/' ;;
    argocd)       printf '%s\n' 'https://127.0.0.1:18081/' ;;
    prometheus)   printf '%s\n' 'http://127.0.0.1:18090/' ;;
    alertmanager) printf '%s\n' 'http://127.0.0.1:18093/' ;;
  esac
}

# Prefer the chart's named Service; discover it by port if Helm naming changes.
service_for() {
  local namespace="$1" preferred="$2" port="$3"
  if kubectl --context "$CONTEXT" -n "$namespace" get svc "$preferred" >/dev/null 2>&1; then
    printf '%s\n' "$preferred"
    return 0
  fi
  kubectl --context "$CONTEXT" -n "$namespace" get svc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.ports[*]}{.port}{","}{end}{"\n"}{end}' \
    | awk -F '|' -v p="$port" '$2 ~ ("(^|,)" p "(,|$)") {print $1; exit}'
}

pid_is_alive() {
  local pidfile="$STATE_DIR/$1.pid" pid
  [[ -f "$pidfile" ]] || return 1
  pid="$(cat "$pidfile")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

start_one() {
  local name="$1" ns="$2" preferred="$3" remote="$4" local_port="$5"
  local svc pid
  if pid_is_alive "$name"; then
    printf 'Already running: %-13s %s\n' "$name" "$(url_for "$name")"
    return 0
  fi
  svc="$(service_for "$ns" "$preferred" "$remote")"
  if [[ -z "$svc" ]]; then
    printf 'ERROR: no Service exposing port %s in namespace %s (%s)\n' "$remote" "$ns" "$name" >&2
    return 1
  fi
  : > "$STATE_DIR/$name.log"
  # Loopback only: no dashboard is exposed on LAN/WAN.
  nohup kubectl --context "$CONTEXT" -n "$ns" port-forward \
    --address 127.0.0.1 "svc/$svc" "${local_port}:${remote}" \
    > "$STATE_DIR/$name.log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$STATE_DIR/$name.pid"
  sleep 1
  if ! pid_is_alive "$name"; then
    printf 'ERROR: %s port-forward exited. Log:\n' "$name" >&2
    sed -n '1,15p' "$STATE_DIR/$name.log" >&2
    rm -f "$STATE_DIR/$name.pid"
    return 1
  fi
  printf 'Started: %-13s %s  [PID %s]\n' "$name" "$(url_for "$name")" "$pid"
}

start_all() {
  command -v kubectl >/dev/null || { echo 'kubectl is not on PATH' >&2; return 1; }
  kubectl --context "$CONTEXT" get namespace kube-system >/dev/null || {
    echo "Cannot access Kubernetes context '$CONTEXT'. Start Minikube first." >&2
    return 1
  }
  local errors=0
  start_one app traefik traefik 80 18080 || errors=1
  start_one argocd argocd argocd-server 443 18081 || errors=1
  start_one prometheus monitoring platformlab-monitoring-kube-pr-prometheus 9090 18090 || errors=1
  start_one alertmanager monitoring platformlab-monitoring-kube-pr-alertmanager 9093 18093 || errors=1
  return "$errors"
}

status_all() {
  local name
  for name in "${names[@]}"; do
    if pid_is_alive "$name"; then
      printf 'RUNNING %-13s %s\n' "$name" "$(url_for "$name")"
    else
      printf 'STOPPED %-13s %s\n' "$name" "$(url_for "$name")"
    fi
  done
}

stop_all() {
  local name pidfile pid
  for name in "${names[@]}"; do
    pidfile="$STATE_DIR/$name.pid"
    if [[ -f "$pidfile" ]]; then
      pid="$(cat "$pidfile")"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        printf 'Stopped: %s\n' "$name"
      fi
      rm -f "$pidfile"
    fi
  done
}

# Use the host's default browser. Headless systems can open the printed URLs
# manually. Do not require Windows-specific executables on Linux or macOS.
open_url() {
  local url="$1"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      command -v explorer.exe >/dev/null 2>&1 && explorer.exe "$url" ;;
    Darwin*)
      command -v open >/dev/null 2>&1 && open "$url" ;;
    *)
      # WSL or a headless Linux host may have xdg-open but no desktop session.
      if command -v xdg-open >/dev/null 2>&1 && xdg-open "$url"; then return 0; fi
      if command -v wslview >/dev/null 2>&1 && wslview "$url"; then return 0; fi
      if command -v explorer.exe >/dev/null 2>&1 && explorer.exe "$url"; then return 0; fi
      return 1 ;;
  esac
}

open_all() {
  local name url failures=0
  for name in "${names[@]}"; do
    url="$(url_for "$name")"
    if ! open_url "$url" >/dev/null 2>&1; then
      printf '[WARN] Browser could not open %s: %s\n' "$name" "$url" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    printf '[INFO] Open these URLs manually if your system has no browser.\n'
    status_all
  fi
  return 0
}

case "${1:-}" in
  start)  start_all ;;
  status) status_all ;;
  stop)   stop_all ;;
  open)   open_all ;;
  logs)   for name in "${names[@]}"; do printf '\n--- %s ---\n' "$name"; tail -n 8 "$STATE_DIR/$name.log" 2>/dev/null || true; done ;;
  -h|--help|help)
         printf '%s\n' 'PlatformLab - local UI access (Windows Git Bash / Linux / macOS)' \
           'Usage: bash scripts/platformlab-uis.sh start|status|open|stop|logs' \
           'Browser opening uses explorer.exe, xdg-open or open when available.' ;;
  *)     echo 'Usage: bash scripts/platformlab-uis.sh start|status|open|stop|logs' >&2; exit 2 ;;
esac
