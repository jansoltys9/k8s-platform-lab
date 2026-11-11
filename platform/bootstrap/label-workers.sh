#!/usr/bin/env bash
set -euo pipefail

if [[ "$(kubectl config current-context)" != "platformlab" ]]; then
  echo "Wrong Kubernetes context"
  exit 1
fi

kubectl label node platformlab-m02 \
  workload-tier=apps \
  platformlab.io/pool=workers --overwrite

kubectl label node platformlab-m03 \
  workload-tier=monitoring \
  platformlab.io/pool=workers --overwrite
