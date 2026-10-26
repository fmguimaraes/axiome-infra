#!/usr/bin/env bash
# One-time AXI-1950 on-box conversion of an environment's box (Phase 3a–3d of
# the power-on/off runbook), so the deploy workflow's preflight accepts it.
#
#   scripts/onbox-convert.sh <environment> <ssm-prefix> <onbox-s3-prefix>
#   e.g. scripts/onbox-convert.sh production /production/axiome-production \
#          s3://axiome-production-system/onbox
#
# Restarts nothing. Refuses to continue if the box's compose file has anything
# the repo's does not (the new file must be a pure superset). Idempotent: a box
# that already runs boot.sh is reported and left alone.
# Rollback: restore /opt/axiome/docker-compose.yml.prev and
# /etc/systemd/system/axiome.service.pre-AXI-1944, then systemctl daemon-reload.
set -euo pipefail

ENVIRONMENT="${1:?environment required}"
SSM_PREFIX="${2:?ssm prefix required}"
ONBOX_PREFIX="${3:?onbox s3 prefix required}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSM_EXEC="${REPO_ROOT}/scripts/ssm-exec.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

box() { "$SSM_EXEC" -e "$ENVIRONMENT" "$1" 2>/dev/null; }

echo "== 3b. compose superset check"
box 'cat /opt/axiome/docker-compose.yml' > "$TMP/box-compose.yml"
[ -s "$TMP/box-compose.yml" ] || { echo "ERROR: could not read the box compose file" >&2; exit 1; }
if diff "$TMP/box-compose.yml" "${REPO_ROOT}/providers/aws/onbox/docker-compose.yml" | grep -q '^<'; then
  diff "$TMP/box-compose.yml" "${REPO_ROOT}/providers/aws/onbox/docker-compose.yml" | grep '^<' >&2
  echo "ERROR: the box compose file has lines the repo's does not — refusing to overwrite them" >&2
  exit 1
fi
echo "ok: repo compose is a pure superset of the box's"

if box 'systemctl cat axiome.service' | grep -q '^ExecStart=/opt/axiome/scripts/boot.sh'; then
  echo "== box already converted (ExecStart is boot.sh) — nothing to do"
  exit 0
fi

echo "== 3a. publish the on-box bundle"
"${REPO_ROOT}/scripts/asset-sync.sh" publish "$REPO_ROOT" "$ONBOX_PREFIX"

echo "== 3c. pull the bundle onto the box"
box "mkdir -p /opt/axiome/scripts && cp -p /opt/axiome/docker-compose.yml /opt/axiome/docker-compose.yml.prev && aws s3 cp ${ONBOX_PREFIX}/scripts/asset-sync.sh /opt/axiome/scripts/asset-sync.sh && chmod 700 /opt/axiome/scripts/asset-sync.sh && /opt/axiome/scripts/asset-sync.sh pull ${ONBOX_PREFIX} /opt/axiome; echo pull-exit=\$?" | tee "$TMP/pull.log"
grep -q '^pull-exit=0$' "$TMP/pull.log" || { echo "ERROR: asset-sync pull failed on the box" >&2; exit 1; }

echo "== 3d. point systemd at boot.sh (no restart)"
box "cd /etc/systemd/system && cp axiome.service axiome.service.pre-AXI-1944 && sed -i '/^\[Service\]/,/^\[/{/^\(WorkingDirectory\|Environment\|ExecStart\|TimeoutStartSec\)=/d}' axiome.service && sed -i '/^\[Service\]/a WorkingDirectory=/opt/axiome\nEnvironment=AXIOME_DIR=/opt/axiome\nEnvironment=ONBOX_S3_PREFIX=${ONBOX_PREFIX}\nEnvironment=SSM_PARAMETER_PREFIX=${SSM_PREFIX}\nExecStart=/opt/axiome/scripts/boot.sh\nTimeoutStartSec=300' axiome.service && systemctl daemon-reload && systemctl cat axiome.service" | tee "$TMP/unit.txt"
grep -q '^ExecStart=/opt/axiome/scripts/boot.sh' "$TMP/unit.txt" || { echo "ERROR: unit was not rewritten" >&2; exit 1; }
grep -q '^ExecStop=' "$TMP/unit.txt" || { echo "ERROR: ExecStop lost from the unit" >&2; exit 1; }

echo "== verify"
box 'ls -l /opt/axiome/scripts /opt/axiome/docker-compose.yml*; docker ps --format "{{.Names}} {{.Status}}" | sort'
echo "DONE: ${ENVIRONMENT} box converted; nothing restarted."
