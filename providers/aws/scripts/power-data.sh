#!/usr/bin/env bash
# power-data.sh — park the DATA tier of an Axiome AWS environment for a long
# idle window (≥ days). SEPARATE from power.sh on purpose: this touches storage
# and is destructive-by-design for ElastiCache, so it must never be on the same
# safe daily path as the compute toggle.
#
# RDS Postgres       -> stop-db-instance / start-db-instance.
#                       ⚠ AWS auto-restarts a stopped RDS after 7 DAYS. For a
#                       longer window, re-run `down` around day 6, or accept the
#                       few days of restarted billing. Never deleted: prod has
#                       deletion_protection = true. An alert fires on this event
#                       (FR35, providers/aws/modules/alerting) and `status`
#                       below shows how long RDS has been stopped.
# ElastiCache Redis  -> snapshot -> delete -> restore (it cannot be "stopped").
#                       `down` captures the live config to S3, requests a FINAL
#                       snapshot as part of deleting the replication group,
#                       then WAITS until that snapshot is confirmed `available`
#                       before reporting success (FR33) — never reports success
#                       on an unverified snapshot. `up` recreates it from that
#                       snapshot with the captured config.
#
# ‼ terraform-cd MUST be gated for the whole down→up window. Deleting the
#   replication group leaves Terraform state referencing a resource that no
#   longer exists; a CD apply mid-window would recreate it EMPTY (data loss) and
#   drift. Recreate uses the same id/config so Terraform re-adopts it cleanly.
#
# LOCKING (FR29, scripts/lock.sh — epic AXI-1944 decision 6, AXI-1947):
#   `down` ACQUIRES the data-tier lock before touching anything and does NOT
#   release it on exit (success OR failure) — `data-tier` has no automatic
#   release by any route (scripts/lock.sh refuses to even register it for
#   auto-release). The acquired token is recorded to
#   s3://<bucket>/power-data/park-state.env (alongside the existing
#   redis-state.env this script already writes) so a LATER, possibly
#   different, `up` invocation can find it. `up` releases the lock ONLY after
#   BOTH RDS and Redis are verified `available` (FR34) — never from a
#   trap/finally, exactly as scripts/lock.sh's header requires for this lock
#   name.
#
#   Residual race this closes, and the part it does NOT close (by design —
#   see scripts/lock.sh's own "Follow-ups" and this story's handback): the
#   `terraform-cd` workflow reads the data-tier lock twice (before `plan`,
#   again before `apply`) but holds nothing of its own during `apply`. Once
#   `down` has acquired the lock, ANY `terraform-cd` run whose own lock check
#   happens AFTER that point is correctly refused. The gap that remains is an
#   `apply` whose *second* lock check already passed BEFORE `down` acquires —
#   i.e. a race only within the few seconds between terraform-cd's own
#   pre-apply check and this script's acquire. Closing that residual window
#   completely would require terraform-cd itself to hold the lock across the
#   whole `apply` step (a workflow-file change), which is out of this
#   script's reach and out of this story's file ownership — flagged to the
#   lead rather than done here.
#
# Usage:  ./power-data.sh <dev|staging|production> <down|up|status>
# Env overrides: AWS_REGION, AXIOME_PROJECT, AXIOME_SYSTEM_BUCKET, REPORTS_DIR,
#                DATA_UP_TIMEOUT (seconds, default 1200), DATA_UP_POLL_INTERVAL
#                (seconds, default 15), REDIS_SNAPSHOT_TIMEOUT (seconds,
#                default 1200)
set -euo pipefail

usage() { echo "usage: $0 <dev|staging|production> <down|up|status>" >&2; exit 2; }
[ $# -eq 2 ] || usage
ENV="$1"; ACTION="$2"
case "$ENV" in dev|staging|production) ;; *) usage ;; esac
case "$ACTION" in down|up|status) ;; *) usage ;; esac

PROJECT="${AXIOME_PROJECT:-axiome}"
REGION="${AWS_REGION:-eu-west-3}"
SYSTEM_BUCKET="${AXIOME_SYSTEM_BUCKET:-${PROJECT}-${ENV}-system}"
RDS_ID="${PROJECT}-${ENV}-pg"
RG_ID="${PROJECT}-${ENV}-redis"
STATE_KEY="power-data/redis-state.env"
STATE_S3="s3://${SYSTEM_BUCKET}/${STATE_KEY}"
PARK_STATE_KEY="power-data/park-state.env"
PARK_STATE_S3="s3://${SYSTEM_BUCKET}/${PARK_STATE_KEY}"
DATA_UP_TIMEOUT="${DATA_UP_TIMEOUT:-1200}"
DATA_UP_POLL_INTERVAL="${DATA_UP_POLL_INTERVAL:-15}"
REDIS_SNAPSHOT_TIMEOUT="${REDIS_SNAPSHOT_TIMEOUT:-1200}"

# scripts/lock.sh (sourced as a library, AXI-1947) also sources
# scripts/lib/report.sh internally — that supersedes this script's previous
# direct source of _power_lib.sh (same report_init/section/line/finish/
# log_event call shapes, plus report_override + the NFR3 secret-shape guard
# this script now needs for lock-related audit lines). REPO_ROOT is resolved
# the same way _power_lib.sh did (git, with an explicit-override escape
# hatch tests use) because lock.sh is addressed relative to it.
_pd_dir="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$_pd_dir" rev-parse --show-toplevel 2>/dev/null || echo "${_pd_dir}/../../..")}"
# shellcheck source=../../../scripts/lock.sh
. "${REPO_ROOT}/scripts/lock.sh"

rds_state()   { aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$RDS_ID" \
                  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent; }
redis_state() { aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$RG_ID" \
                  --query 'ReplicationGroups[0].Status' --output text 2>/dev/null || echo absent; }

# --- park-state.env (lock token + RDS-stop timestamp; FR29/FR35) --------------
# Returns non-zero (never masked, never `|| true`) on an upload failure so
# every caller can decide what "the token didn't get recorded" means for it
# — the first call site (right after lock_acquire, before any mutation)
# treats that as a reason to release the lock and abort; later call sites
# (updating RDS_STOPPED_AT, etc.) treat it as a reason to abort leaving the
# lock HELD, since by then something may already have been mutated.
write_park_state() { # token rds_stopped_at(iso or empty)
  local token="$1" rds_at="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
LOCK_TOKEN="${token}"
RDS_STOPPED_AT="${rds_at}"
PARKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
  if ! aws s3 cp "$tmp" "$PARK_STATE_S3" --region "$REGION" >/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}
read_park_state_field() { # <FIELD>
  local field="$1" tmp val
  tmp="$(mktemp)"
  if ! aws s3 cp "$PARK_STATE_S3" "$tmp" --region "$REGION" >/dev/null 2>&1; then
    rm -f "$tmp"
    printf ''
    return 0
  fi
  val="$(sed -n "s/^${field}=\"\\(.*\\)\"\$/\\1/p" "$tmp")"
  rm -f "$tmp"
  printf '%s' "$val"
}
clear_park_state() {
  aws s3 rm "$PARK_STATE_S3" --region "$REGION" >/dev/null 2>&1 || true
}

# FR35: status shows how long RDS has been stopped — read from our own
# recorded stop time (AWS exposes no "time stopped" field on a stopped RDS
# instance), so this reflects the last time THIS script requested the stop.
rds_stopped_duration() {
  local at age
  at="$(read_park_state_field RDS_STOPPED_AT)"
  [ -n "$at" ] || { echo "unknown (no recorded stop time)"; return 0; }
  local stopped_epoch
  stopped_epoch="$(date -u -d "${at}" +%s 2>/dev/null || echo "")"
  [ -n "$stopped_epoch" ] || { echo "unknown (unparseable recorded timestamp)"; return 0; }
  age=$(( $(date -u +%s) - stopped_epoch ))
  [ "$age" -ge 0 ] || { echo "unknown (recorded timestamp is in the future)"; return 0; }
  printf '%dd %dh (stopped at %s)\n' $((age / 86400)) $(((age % 86400) / 3600)) "$at"
}

# --- bounded polls (FR33/FR34) — never `|| true`, always a defined timeout --
wait_for_state() { # <rds|redis> <id> <target-state> <timeout-seconds>
  local kind="$1" target="$3" timeout="$4" deadline cur
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    case "$kind" in
      rds)   cur="$(rds_state)"   ;;
      redis) cur="$(redis_state)" ;;
    esac
    [ "$cur" = "$target" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$DATA_UP_POLL_INTERVAL"
  done
}

wait_for_redis_snapshot_available() { # <snapshot-name>
  local snap="$1" deadline st
  deadline=$(( $(date +%s) + REDIS_SNAPSHOT_TIMEOUT ))
  while :; do
    st="$(aws elasticache describe-snapshots --region "$REGION" --snapshot-name "$snap" \
      --query 'Snapshots[0].SnapshotStatus' --output text 2>/dev/null || echo absent)"
    [ "$st" = "available" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$DATA_UP_POLL_INTERVAL"
  done
}

# ------------------------------------------------------------------------------
# capture_redis_config — persists the live Redis config BEFORE `down` is
# allowed to delete the replication group. Bounce #1 fix: `read -r ... <<<
# "$(aws ...)"` always succeeds (read's own exit status, not the describe
# call's), so a failed describe call used to silently produce empty fields
# that got saved and then Redis got deleted anyway. Now: every describe
# call's own exit status is checked, every captured field is checked
# non-empty (AWS CLI text output for a missing scalar is the literal
# "None", also rejected), the config is read back from S3 after writing it
# and compared byte-for-byte, and ONLY THEN does this return the snapshot
# name — the caller never deletes Redis unless this returns successfully.
capture_redis_config() {
  local stamp snap cc_out rg_out ev pg subnet sg node kms window desc \
        verify_tmp field val
  stamp="$(date -u +%Y%m%d-%H%M)"
  snap="${RG_ID}-final-${stamp}"

  if ! cc_out="$(aws elasticache describe-cache-clusters --region "$REGION" \
       --cache-cluster-id "${RG_ID}-001" \
       --query 'CacheClusters[0].[EngineVersion,CacheParameterGroup.CacheParameterGroupName,CacheSubnetGroupName,SecurityGroups[0].SecurityGroupId]' \
       --output text 2>&1)"; then
    echo "capture_redis_config: describe-cache-clusters failed: ${cc_out}" >&2
    return 1
  fi
  read -r ev pg subnet sg <<<"$cc_out"

  if ! rg_out="$(aws elasticache describe-replication-groups --region "$REGION" \
       --replication-group-id "$RG_ID" \
       --query 'ReplicationGroups[0].[CacheNodeType,KmsKeyId,SnapshotWindow]' --output text 2>&1)"; then
    echo "capture_redis_config: describe-replication-groups (node/kms/window) failed: ${rg_out}" >&2
    return 1
  fi
  read -r node kms window <<<"$rg_out"

  if ! desc="$(aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$RG_ID" \
       --query 'ReplicationGroups[0].Description' --output text 2>&1)"; then
    echo "capture_redis_config: describe-replication-groups (description) failed: ${desc}" >&2
    return 1
  fi

  for field in ev pg subnet sg node kms window; do
    val="${!field}"
    case "$val" in
      "" | None | none)
        echo "capture_redis_config: field '${field}' came back empty/None — refusing an incomplete config" >&2
        return 1
        ;;
    esac
  done

  cat > /tmp/redis-state.env <<EOF
RG_ID="${RG_ID}"
NODE="${node}"
ENGINE_VERSION="${ev}"
PARAM_GROUP="${pg}"
SUBNET_GROUP="${subnet}"
SG_IDS="${sg}"
KMS="${kms}"
WINDOW="${window}"
DESC="${desc}"
SNAPSHOT_NAME="${snap}"
EOF

  aws s3 cp /tmp/redis-state.env "$STATE_S3" --region "$REGION" >/dev/null || {
    echo "capture_redis_config: failed to persist config to ${STATE_S3}" >&2
    return 1
  }

  # Read the config back and compare byte-for-byte before trusting it —
  # the review explicitly asked for this, on top of the field checks above.
  verify_tmp="$(mktemp)"
  if ! aws s3 cp "$STATE_S3" "$verify_tmp" --region "$REGION" >/dev/null 2>&1; then
    rm -f "$verify_tmp"
    echo "capture_redis_config: could not read back ${STATE_S3} after writing it — refusing to proceed" >&2
    return 1
  fi
  if ! diff -q /tmp/redis-state.env "$verify_tmp" >/dev/null 2>&1; then
    rm -f "$verify_tmp"
    echo "capture_redis_config: readback of ${STATE_S3} does not match what was written — refusing to proceed" >&2
    return 1
  fi
  rm -f "$verify_tmp"

  echo "$snap"
}

case "$ACTION" in
  status)
    echo "${ENV} data tier:"
    echo "  RDS   ${RDS_ID}: $(rds_state)"
    if [ "$(rds_state)" = "stopped" ]; then
      echo "  RDS stopped-duration: $(rds_stopped_duration)"
    fi
    echo "  Redis ${RG_ID}: $(redis_state)"
    lock_status "$ENV" data-tier || true
    # FR44 (AXI-1967): surface a park-state record left behind by an
    # operator `lock.sh override` of the data-tier lock — status must
    # report it clearly rather than staying silent about it.
    PARK_TOKEN_STATUS="$(read_park_state_field LOCK_TOKEN)"
    if [ -n "$PARK_TOKEN_STATUS" ]; then
      echo "  park-state record: PRESENT at ${PARK_STATE_S3} (token=${PARK_TOKEN_STATUS}, parked_at=$(read_park_state_field PARKED_AT))"
      set +e
      lock_status "$ENV" data-tier >/dev/null 2>&1
      LOCK_FREE_RC=$?
      set -e
      if [ "$LOCK_FREE_RC" -eq "$LOCK_RC_OK" ]; then
        echo "  WARNING: the data-tier lock is FREE but a park-state record remains — an operator 'override' likely removed the lock without running 'up'. Run '$0 ${ENV} up' to verify both tiers and clear this record (FR44)."
      fi
    else
      echo "  park-state record: none"
    fi
    ;;

  down)
    echo "== ${ENV} data-tier DOWN =="
    set +e
    LOCK_OUT="$(lock_acquire "$ENV" data-tier "data-tier down (compute/data park)" 2>&1)"
    LOCK_RC=$?
    set -e
    echo "$LOCK_OUT"
    if [ "$LOCK_RC" -ne "$LOCK_RC_OK" ]; then
      echo "ABORT: could not acquire the data-tier lock (rc=${LOCK_RC}) — refusing to park. Another park, deploy, or terraform-cd apply may be in progress; see '$0 ${ENV} status'." >&2
      exit 1
    fi
    TOKEN="$(printf '%s\n' "$LOCK_OUT" | sed -n 's/.*token=\([^ ]*\).*/\1/p')"
    if [ -z "$TOKEN" ]; then
      echo "ABORT: lock reported acquired but no token could be parsed from its output — refusing to proceed without a release token." >&2
      exit 1
    fi

    # FR43 (AXI-1967): data-tier is acquired FIRST (above); now verify
    # deploy and apply are both free before any AWS mutation. On refusal,
    # release the data-tier lock this call just took and remove any
    # park-state it wrote (none yet, at this point, but defensive — see
    # the write below) so the refusal leaves nothing behind.
    if ! lock_require_free "$ENV" deploy; then
      echo "ABORT: the deploy lock is held — releasing the data-tier lock just acquired and refusing to park while a deploy is in progress." >&2
      set +e
      lock_release "$ENV" data-tier "$TOKEN" >&2
      set -e
      clear_park_state
      exit 1
    fi
    if ! lock_require_free "$ENV" apply; then
      echo "ABORT: the apply lock is held — releasing the data-tier lock just acquired and refusing to park while a Terraform apply is in progress." >&2
      set +e
      lock_release "$ENV" data-tier "$TOKEN" >&2
      set -e
      clear_park_state
      exit 1
    fi

    # Bounce #1 fix: write park-state IMMEDIATELY after the lock is
    # acquired and BEFORE any stop/delete — the old ordering only wrote it
    # after RDS was stopped AND Redis deleted, so an abort anywhere in
    # between left the lock HELD with its release token nowhere recorded.
    # If THIS write itself fails, nothing has been touched yet: release the
    # lock we just took, change nothing, and exit non-zero saying so.
    if ! write_park_state "$TOKEN" ""; then
      echo "ABORT: could not write ${PARK_STATE_S3} immediately after acquiring the lock — releasing the lock now (nothing was touched) and exiting." >&2
      set +e
      lock_release "$ENV" data-tier "$TOKEN" >&2
      set -e
      exit 1
    fi

    report_init "$ENV" "data-down"
    report_line "data-tier lock ACQUIRED (FR29) — held until a later 'up' verifies availability; never auto-released."
    report_section "Before"
    report_line "RDS ${RDS_ID}: $(rds_state)"
    report_line "Redis ${RG_ID}: $(redis_state)"
    report_section "Actions"

    RDS_STOPPED_AT=""
    # 1) RDS: stop (never delete — deletion_protection on prod)
    if [ "$(rds_state)" = "available" ]; then
      aws rds stop-db-instance --region "$REGION" --db-instance-identifier "$RDS_ID" >/dev/null
      RDS_STOPPED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # Record the newly-known stop time now (later fact, per the review) —
      # a failure here does NOT undo the stop (RDS stop/start is safe to
      # retry and is not "destruction"); it is reported, never masked, and
      # the final write below gets another chance to persist it.
      write_park_state "$TOKEN" "$RDS_STOPPED_AT" \
        || echo "WARNING: could not update ${PARK_STATE_S3} with RDS_STOPPED_AT yet — will retry after the Redis step." >&2
      log_event "$ENV" "RDS ${RDS_ID}" "available -> stopping (AWS auto-restarts after 7d)"
      report_line "RDS ${RDS_ID}: stop requested (auto-restarts after 7d; FR35 alert covers that event)."
    else
      echo "  RDS not 'available' (state: $(rds_state)) — skipping stop"
      report_line "RDS ${RDS_ID}: skipped (state $(rds_state))."
    fi

    # 2) ElastiCache: capture+verify config FIRST (bounce #1 fix) — Redis is
    # deleted ONLY if capture_redis_config returns successfully (every
    # describe call's exit status checked, every field non-empty, config
    # read back and compared after writing). Then final snapshot -> WAIT
    # for it to be verified available (FR33) before this script ever
    # reports success.
    if [ "$(redis_state)" = "available" ]; then
      if ! SNAP="$(capture_redis_config)"; then
        write_park_state "$TOKEN" "$RDS_STOPPED_AT" \
          || echo "WARNING: could not update ${PARK_STATE_S3} on this abort path." >&2
        report_line "Redis ${RG_ID}: configuration capture FAILED or was incomplete — ABORTING before any delete; Redis untouched. data-tier lock REMAINS HELD (FR29)."
        report_finish
        echo "ABORT: could not capture/verify a complete Redis configuration — Redis NOT deleted. Lock HELD." >&2
        exit 1
      fi
      echo "  config saved to ${STATE_S3}; requesting final snapshot ${SNAP} and deleting the replication group..."
      aws elasticache delete-replication-group --region "$REGION" \
        --replication-group-id "$RG_ID" --final-snapshot-identifier "$SNAP" >/dev/null
      report_line "Redis ${RG_ID}: config -> ${STATE_S3}; final snapshot ${SNAP} requested; verifying availability (FR33)..."
      if wait_for_redis_snapshot_available "$SNAP"; then
        log_event "$ENV" "Redis ${RG_ID}" "final snapshot ${SNAP} verified available; replication group deleting"
        report_line "Redis ${RG_ID}: final snapshot ${SNAP} verified AVAILABLE (FR33). Replication group deleting."
      else
        write_park_state "$TOKEN" "$RDS_STOPPED_AT" \
          || echo "WARNING: could not update ${PARK_STATE_S3} on this abort path." >&2
        report_line "Redis ${RG_ID}: final snapshot ${SNAP} NOT verified available within ${REDIS_SNAPSHOT_TIMEOUT}s — data-tier lock REMAINS HELD (FR29); investigate (aws elasticache describe-snapshots) before trusting this backup or retrying."
        report_finish
        echo "ABORT: Redis final snapshot ${SNAP} not confirmed available within ${REDIS_SNAPSHOT_TIMEOUT}s. Lock HELD — do not release manually until the snapshot is confirmed." >&2
        exit 1
      fi
    else
      echo "  Redis not 'available' (state: $(redis_state)) — skipping snapshot/delete"
      report_line "Redis ${RG_ID}: skipped (state $(redis_state))."
    fi

    write_park_state "$TOKEN" "$RDS_STOPPED_AT" \
      || echo "WARNING: could not write the final ${PARK_STATE_S3} update (lock token from the EARLIER write is still recorded; RDS_STOPPED_AT may be stale)." >&2
    report_section "After"
    report_line "RDS ${RDS_ID}: $(rds_state)"
    report_line "Redis ${RG_ID}: $(redis_state)"
    report_line "data-tier lock HELD (token recorded at ${PARK_STATE_S3}) — run '$0 ${ENV} up' to restore; it releases the lock only after verified availability."
    report_finish
    echo "done. Data-tier LOCK HELD (FR29) — keep terraform-cd gated until you run '$0 ${ENV} up'."
    ;;

  up)
    echo "== ${ENV} data-tier UP =="
    report_init "$ENV" "data-up"
    report_section "Before"
    report_line "RDS ${RDS_ID}: $(rds_state)"
    report_line "Redis ${RG_ID}: $(redis_state)"

    # FR43 (AXI-1967): require deploy and apply free before any RDS/Redis
    # mutation. The data-tier lock itself is THIS park's own lock (acquired
    # by the earlier `down`, not by this `up` invocation) — it must NOT be
    # released on a refusal here; only an operator/the later verified
    # release path ever clears it.
    if ! lock_require_free "$ENV" deploy; then
      report_line "ABORT: the deploy lock is held — refusing to unpark while a deploy is in progress. The data-tier lock itself is untouched (it is this park's own lock)."
      report_finish "failed-deploy-held"
      echo "ABORT: the deploy lock for ${ENV} is held — refusing to start/recreate the data tier while a deploy is in progress. Re-run '$0 ${ENV} up' once the deploy finishes." >&2
      exit 1
    fi
    if ! lock_require_free "$ENV" apply; then
      report_line "ABORT: the apply lock is held — refusing to unpark while a Terraform apply is in progress. The data-tier lock itself is untouched (it is this park's own lock)."
      report_finish "failed-apply-held"
      echo "ABORT: the apply lock for ${ENV} is held — refusing to start/recreate the data tier while a Terraform apply is in progress. Re-run '$0 ${ENV} up' once the apply finishes." >&2
      exit 1
    fi

    report_section "Actions"
    # 1) RDS: start if stopped. EC8: if AWS already auto-restarted it, treat
    # "available" as already started and still run every verification below.
    case "$(rds_state)" in
      stopped) aws rds start-db-instance --region "$REGION" --db-instance-identifier "$RDS_ID" >/dev/null
               log_event "$ENV" "RDS ${RDS_ID}" "stopped -> starting"
               report_line "RDS ${RDS_ID}: start requested." ;;
      available) echo "  RDS already available — skipping start (EC8: may have been AWS's 7-day auto-restart)"
               report_line "RDS ${RDS_ID}: already available (EC8 — treated as already started; still verified below)." ;;
      *) echo "  RDS state: $(rds_state) — not starting"
               report_line "RDS ${RDS_ID}: not started (state $(rds_state))." ;;
    esac
    # 2) ElastiCache: recreate from snapshot + captured config
    if [ "$(redis_state)" = "absent" ]; then
      aws s3 cp "$STATE_S3" /tmp/redis-state.env --region "$REGION" >/dev/null
      # shellcheck disable=SC1091
      . /tmp/redis-state.env
      # ElastiCache create-replication-group rejects a patch version (e.g.
      # "7.1.0" -> InvalidParameterValue); it wants major.minor ("7.1").
      # Normalize a captured X.Y.Z down to X.Y; leave X.Y untouched.
      EV_CREATE="$(printf '%s' "$ENGINE_VERSION" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/')"
      echo "  recreating ${RG_ID} from ${SNAPSHOT_NAME} (engine ${EV_CREATE})..."
      aws elasticache create-replication-group --region "$REGION" \
        --replication-group-id "$RG_ID" \
        --replication-group-description "$DESC" \
        --snapshot-name "$SNAPSHOT_NAME" \
        --engine redis --engine-version "$EV_CREATE" \
        --cache-node-type "$NODE" --num-cache-clusters 1 \
        --cache-subnet-group-name "$SUBNET_GROUP" \
        --security-group-ids $SG_IDS \
        --cache-parameter-group-name "$PARAM_GROUP" \
        --port 6379 --snapshot-retention-limit 0 --snapshot-window "$WINDOW" \
        --at-rest-encryption-enabled --kms-key-id "$KMS" \
        --transit-encryption-enabled --transit-encryption-mode required >/dev/null
      log_event "$ENV" "Redis ${RG_ID}" "recreating from snapshot ${SNAPSHOT_NAME}"
      report_line "Redis ${RG_ID}: recreating from snapshot ${SNAPSHOT_NAME}."
    else
      echo "  Redis state: $(redis_state) — not recreating"
      report_line "Redis ${RG_ID}: not recreated (state $(redis_state))."
    fi

    echo "waiting (bounded, FR34) for RDS available + Redis available..."
    if ! wait_for_state rds "$RDS_ID" available "$DATA_UP_TIMEOUT"; then
      report_line "RDS ${RDS_ID}: NOT available within ${DATA_UP_TIMEOUT}s — data-tier lock remains HELD (FR34); exiting non-zero."
      report_finish
      echo "FAIL: RDS not available within ${DATA_UP_TIMEOUT}s. Lock remains held — investigate, then re-run '$0 ${ENV} up'." >&2
      exit 1
    fi
    if ! wait_for_state redis "$RG_ID" available "$DATA_UP_TIMEOUT"; then
      report_line "Redis ${RG_ID}: NOT available within ${DATA_UP_TIMEOUT}s — data-tier lock remains HELD (FR34); exiting non-zero."
      report_finish
      echo "FAIL: Redis not available within ${DATA_UP_TIMEOUT}s. Lock remains held — investigate, then re-run '$0 ${ENV} up'." >&2
      exit 1
    fi

    report_section "After"
    report_line "RDS ${RDS_ID}: $(rds_state)"
    report_line "Redis ${RG_ID}: $(redis_state)"

    # FR29: release the data-tier lock ONLY now — both tiers verified
    # available above. Never from a trap/finally (scripts/lock.sh's contract
    # for this lock name); an unreadable/missing token is reported, not
    # masked, and the lock is deliberately left for an operator to resolve
    # via scripts/lock.sh status/override.
    PARK_TOKEN="$(read_park_state_field LOCK_TOKEN)"
    if [ -n "$PARK_TOKEN" ]; then
      set +e
      REL_OUT="$(lock_release "$ENV" data-tier "$PARK_TOKEN" 2>&1)"
      REL_RC=$?
      set -e
      echo "$REL_OUT"
      if [ "$REL_RC" -eq "$LOCK_RC_OK" ]; then
        report_line "data-tier lock RELEASED (verified available)."
        clear_park_state
      else
        # FR44 (AXI-1967): distinguish "the lock was already free" (an
        # operator `lock.sh override` ran while parked — the release is
        # correctly refused, but both tiers ARE now verified available, so
        # the stale park-state record no longer serves any purpose and
        # should not be left for the operator forever) from every OTHER
        # release failure (token mismatch against a different holder,
        # UNKNOWN/transport error) — those leave the record exactly as
        # before, unchanged.
        set +e
        lock_status "$ENV" data-tier >/dev/null 2>&1
        STATUS_RC=$?
        set -e
        if [ "$STATUS_RC" -eq "$LOCK_RC_OK" ]; then
          report_line "NOTICE: the data-tier lock was already free (an operator 'override' removed it) — both tiers are now verified available, so the stale park-state record at ${PARK_STATE_S3} is cleared (FR44)."
          echo "NOTE: the data-tier lock was already free (operator override) — both tiers are verified available; clearing the stale park-state record." >&2
          clear_park_state
        else
          report_line "WARNING: could not auto-release the data-tier lock (rc=${REL_RC}): ${REL_OUT}. Run: scripts/lock.sh ${ENV} status data-tier"
        fi
      fi
    else
      report_line "WARNING: no recorded lock token at ${PARK_STATE_S3} — lock NOT auto-released. Check: scripts/lock.sh ${ENV} status data-tier"
    fi
    report_line "**Next:** re-enable terraform-cd (a plan should show NO changes)."
    report_finish
    echo "data tier UP (verified). Now re-enable terraform-cd (a plan should show NO changes)."
    ;;

  *) usage ;;
esac
