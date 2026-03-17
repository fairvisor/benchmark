#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT_DIR}/run-all.sh"

DRY_RUN=1 \
FAIRVISOR_REMOTE="${FAIRVISOR_REMOTE:-ubuntu@fairvisor-host}" \
LOADGEN_REMOTE="${LOADGEN_REMOTE:-ubuntu@loadgen-host}" \
FAIRVISOR_TARGET_HOST="${FAIRVISOR_TARGET_HOST:-10.0.0.42}" \
bash "${ROOT_DIR}/run-all.sh" >/dev/null

echo "smoke ok"
