#!/usr/bin/env bash
# Full-lab storage owner: Minikube CSI HostPath addon + GitOps StorageClass.
# This helper never deletes PVs, PVCs, or CSI volumes.
# The existing-lab start helper also runs reconcile after its PVC safety checks.
set -Eeuo pipefail

ACTION="${1:-status}"
if (( $# > 0 )); then shift; fi
PROFILE="${PLATFORMLAB_PROFILE:-platformlab}"
CONTEXT="${PLATFORMLAB_CONTEXT:-platformlab}"
STRICT=false
CSI_DRIVER="hostpath.csi.k8s.io"
CSI_CLASS="platformlab-csi-wffc"

usage() {
  cat <<'HELP'
PlatformLab full-lab storage (Windows Git Bash / Linux / macOS)

  bash scripts/platformlab-storage.sh status [--strict]
  bash scripts/platformlab-storage.sh reconcile

  --profile NAME   Minikube profile (default: platformlab)
  --context NAME   Kubernetes context (default: platformlab)

  status     Read-only: addon states, CSI readiness, StorageClass and PVCs.
  --strict   Also require the GitOps StorageClass to be the sole default.
  reconcile  Idempotent addon alignment (also called by platformlab-env.sh start):
             enable CSI, disable old addons, demote legacy default classes.

This operates on the FULL three-node lab. The single-node reviewer demo
is a separate profile and does not require CSI HostPath monitoring PVCs.
No PV, PVC, workload or application is deleted by this script.
HELP
}

while (( $# )); do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || { echo '[ERROR] --profile needs a value.' >&2; exit 2; }; PROFILE="$2"; shift 2 ;;
    --context) [[ $# -ge 2 ]] || { echo '[ERROR] --context needs a value.' >&2; exit 2; }; CONTEXT="$2"; shift 2 ;;
    --strict) STRICT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$ACTION" in
  status|reconcile) ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "[ERROR] Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac
[[ "$ACTION" != reconcile || "$STRICT" == false ]] || {
  echo '[ERROR] --strict applies only to status.' >&2; exit 2;
}

log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
k()    { kubectl --context "$CONTEXT" "$@"; }

for bin in kubectl minikube; do
  command -v "$bin" >/dev/null 2>&1 || { err "Missing command: $bin"; exit 1; }
done
k get nodes >/dev/null || { err "Cannot reach context '$CONTEXT'."; exit 1; }

# Keep the profile and context aligned: prevent modifying another cluster.
if [[ "$PROFILE" != "$CONTEXT" ]]; then
  err "Minikube profile '$PROFILE' differs from kubectl context '$CONTEXT'."
  err 'Select matching names before changing infrastructure addons.'
  exit 1
fi

addon_list() { minikube -p "$PROFILE" addons list; }
# Parse Minikube's exact addon-name column before reading its status.
# Clean the entire table FIRST: Git Bash/Minikube may colorize both the
# addon name and the status, and a status may include a checkmark emoji.
addon_state() {
  local rows="$1" addon="$2" esc state
  esc=$'\033'
  rows="${rows//$'\r'/}"
  rows="${rows//│/|}"
  rows="$(printf '%s\n' "$rows" | sed "s/${esc}\[[0-9;]*[[:alpha:]]//g")"
  state="$(printf '%s\n' "$rows" | awk -F '|' -v target="$addon" '
    NF >= 5 {
      name = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != target) next
      status = $4
      sub(/^[[:space:]]+/, "", status)
      if (status ~ /^enabled([[:space:]]|$)/)  { print "enabled"; exit }
      if (status ~ /^disabled([[:space:]]|$)/) { print "disabled"; exit }
      print "unknown"; exit
    }
  ')"
  case "$state" in
    enabled|disabled) printf '%s\n' "$state" ;;
    *)
      printf '[WARN] Cannot parse Minikube addon status for %s. Check the addons list format.\n' "$addon" >&2
      printf 'unknown\n'
      ;;
  esac
}

# Kubernetes uses these annotations to choose an implicit StorageClass.
# Changing default annotations does not migrate or remove existing PVCs.
get_default() {
  k get storageclass "$1" \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true
}

# Refuse to retire the legacy provider if any PVC still depends on it.
check_pvc_owners() {
  local entries namespace name class phase count=0
  entries="$(k get pvc -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.storageClassName}{"|"}{.status.phase}{"\n"}{end}')" || return 1
  while IFS='|' read -r namespace name class phase; do
    [[ -n "$namespace" ]] || continue
    count=$((count + 1))
    if [[ "$class" != "$CSI_CLASS" ]]; then
      err "$namespace/$name uses '${class:-<implicit>}' instead of '$CSI_CLASS'."
      err 'Storage ownership is not unified. Inspect this PVC before changing add-ons.'
      return 1
    fi
    if [[ "$phase" != Bound ]]; then
      warn "$namespace/$name is $phase (expected Bound after deployment)."
    else
      ok "PVC $namespace/$name: $CSI_CLASS / Bound"
    fi
  done <<< "$entries"
  if (( count == 0 )); then log 'No PVCs yet (expected during initial infrastructure setup).'; fi
}

verify_csi() {
  k get csidriver "$CSI_DRIVER" >/dev/null || { err "Missing CSIDriver $CSI_DRIVER"; return 1; }
  # A new cluster may take longer to initialize the CSI sidecars.
  local timeout="180s"
  for controller in daemonset/csi-hostpathplugin statefulset/csi-hostpath-attacher statefulset/csi-hostpath-resizer; do
    log "Checking kube-system/$controller..."
    k -n kube-system rollout status "$controller" --timeout="$timeout" || {
      err "CSI component is not Ready: $controller"
      return 1
    }
  done
  ok 'CSI HostPath driver and controllers are Ready.'
}

report_class() {
  local cls_provisioner cls_binding cls_default
  if ! k get storageclass "$CSI_CLASS" >/dev/null 2>&1; then
    log "GitOps StorageClass '$CSI_CLASS' not present yet (expected before root Sync)."
    [[ "$STRICT" == false ]] || { err "Missing StorageClass '$CSI_CLASS'."; return 1; }
    return 0
  fi
  cls_provisioner="$(k get storageclass "$CSI_CLASS" -o jsonpath='{.provisioner}')"
  cls_binding="$(k get storageclass "$CSI_CLASS" -o jsonpath='{.volumeBindingMode}')"
  if [[ "$cls_provisioner" != "$CSI_DRIVER" || "$cls_binding" != WaitForFirstConsumer ]]; then
    err "StorageClass '$CSI_CLASS' does not match CSI HostPath / WaitForFirstConsumer."
    return 1
  fi
  cls_default="$(get_default "$CSI_CLASS")"
  if [[ "$cls_default" == true ]]; then
    ok "GitOps StorageClass '$CSI_CLASS' is the default (WaitForFirstConsumer)."
  else
    warn "GitOps StorageClass '$CSI_CLASS' is not default yet; merge/sync its updated GitOps manifest."
    [[ "$STRICT" == false ]] || return 1
  fi
  local other
  for other in standard csi-hostpath-sc; do
    if [[ "$(get_default "$other")" == true ]]; then
      warn "StorageClass '$other' is also marked default. Run reconcile after reviewing PVCs."
      [[ "$STRICT" == false ]] || return 1
    fi
  done
}

rows="$(addon_list)" || { err 'Cannot query Minikube add-ons.'; exit 1; }
case "$ACTION" in
  status)
    log "Storage status: Minikube profile=$PROFILE, context=$CONTEXT"
    for addon in csi-hostpath-driver storage-provisioner default-storageclass; do
      state="$(addon_state "$rows" "$addon")"
      log "$addon: $state"
      if [[ "$addon" == csi-hostpath-driver && "$state" != enabled ]] || \
         [[ "$addon" != csi-hostpath-driver && "$state" != disabled ]]; then
        err "Unexpected addon state for '$addon'. Run storage reconcile during maintenance."
        exit 1
      fi
    done
    verify_csi
    check_pvc_owners
    report_class
    ok 'Storage driver and PVC ownership verified.'
    ;;
  reconcile)
    log "Reconciling full-lab storage: Minikube profile=$PROFILE, context=$CONTEXT"
    # Check BEFORE changing any addon: no PVC may rely on the legacy provisioner.
    check_pvc_owners
    csi="$(addon_state "$rows" csi-hostpath-driver)"
    case "$csi" in
      disabled)
        warn 'CSI resources may already exist although the addon is disabled.'
        log 'Enabling the addon may briefly restart CSI Pods; persistent volumes are not deleted.'
        minikube -p "$PROFILE" addons enable csi-hostpath-driver ;;
      enabled) ok 'CSI HostPath addon already enabled.' ;;
      *) err 'Cannot determine CSI addon state. No changes made.'; exit 1 ;;
    esac
    verify_csi
    for addon in storage-provisioner default-storageclass; do
      state="$(addon_state "$rows" "$addon")"
      case "$state" in
        enabled) log "Disabling unused Minikube addon: $addon"; minikube -p "$PROFILE" addons disable "$addon" ;;
        disabled) ok "Legacy addon '$addon' is already disabled." ;;
        *) err "Cannot determine addon state of '$addon'."; exit 1 ;;
      esac
    done
    # The old classes may survive addon disable. Demote them, do not delete them.
    for class in standard csi-hostpath-sc; do
      if [[ "$(get_default "$class")" == true ]]; then
        log "Removing default priority from legacy StorageClass '$class' (annotation only)."
        k annotate storageclass "$class" storageclass.kubernetes.io/is-default-class=false --overwrite
      fi
    done
    rows="$(addon_list)"
    [[ "$(addon_state "$rows" csi-hostpath-driver)" == enabled ]] || { err 'CSI addon did not become enabled.'; exit 1; }
    [[ "$(addon_state "$rows" storage-provisioner)" == disabled ]] || { err 'Legacy storage-provisioner still enabled.'; exit 1; }
    [[ "$(addon_state "$rows" default-storageclass)" == disabled ]] || { err 'Legacy default-storageclass still enabled.'; exit 1; }
    report_class
    ok 'Storage addon ownership aligned. Run status --strict after the GitOps StorageClass sync.'
    ;;
esac
