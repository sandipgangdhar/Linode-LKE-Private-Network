#!/bin/bash
# NOTE: intentionally NOT using `set -e` here (only -u and pipefail).
# Previously this script used `set -euo pipefail`, and the main loop piped
# job results into a `while read` loop (`... | while read; do process_job;
# done`), which bash runs in a subshell. Any single unguarded command inside
# process_job() returning non-zero (a transient linode-cli/curl failure) let
# `set -e` kill that subshell, which - via pipefail - propagated up and
# killed the entire script. The container then restarted, but the code path
# that released the leader lock never ran, permanently wedging the lock with
# no replica ever able to acquire it again (see the lease-based lock below,
# which is the real fix for that specific consequence). A long-running
# daemon loop that must survive a single bad job's failure is fundamentally
# a bad fit for `errexit` semantics - explicit checks (already used
# throughout this file) are safer here than relying on `set -e`.
set -uo pipefail

# ============================================================
# vlan-config-controller (replicas-safe, replicas >= 2)
#
# Jobs:  /vlan-config/<LINODE_ID> -> base64(JSON)
# Leader lock: /vlan-config-controller/leader -> value=<POD_NAME>, bound to
#   an etcd lease with periodic keepalive. If the holder dies for any reason
#   (crash, OOM-kill, eviction, node failure) without explicitly releasing
#   the lock, the lease simply expires within LOCK_LEASE_TTL seconds and
#   another replica can take over - the lock can no longer be stuck forever.
#
# One controller pod wins the leader lock and processes pending jobs.
# ============================================================

# LOG_LEVEL (env, default INFO) gates verbosity: DEBUG < INFO < WARN < ERROR.
log() {
  local level="$1"; shift
  local configured="${LOG_LEVEL:-INFO}"
  local rank threshold
  case "$level" in
    DEBUG) rank=0 ;;
    WARN)  rank=2 ;;
    ERROR) rank=3 ;;
    *)     rank=1 ;;  # INFO and any unrecognized level
  esac
  case "$configured" in
    DEBUG) threshold=0 ;;
    WARN)  threshold=2 ;;
    ERROR) threshold=3 ;;
    *)     threshold=1 ;;
  esac
  (( rank < threshold )) && return 0
  echo "[CONTROLLER] [$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

: "${ETCD_ENDPOINTS:?ETCD_ENDPOINTS not set}"
: "${LINODE_API_KEY:?LINODE_API_KEY not set}"

POD_NAME="${POD_NAME:-${HOSTNAME:-unknown}}"
LOCK_KEY="/vlan-config-controller/leader"
PREFIX="/vlan-config/"

# JOB_WAIT_TIMEOUT_SECONDS: how long process_job() will wait for Linode to
# report "offline" (after shutdown) or "running" (after boot) before giving
# up on that specific job. Without this, a single wedged instance (e.g.
# stuck in "shutting_down" - see docs/TROUBLESHOOTING.md) waits forever,
# and - combined with serial processing - stalls every other node queued
# behind it too. On timeout the job is marked status=failed (with a
# failure_reason and failed_at timestamp) and left alone; it is NOT
# auto-retried by this controller. In practice it still gets retried:
# the vlan-manager DaemonSet pod on that node re-submits a fresh "pending"
# job every time its container restarts and finds VLAN still not attached
# (configure_interfaces() unconditionally overwrites the job), so a
# transient failure heals itself via the pod's own restart loop. A job
# that keeps failing points at a genuinely wedged Linode instance needing
# manual investigation, not a bug in this timeout.
JOB_WAIT_TIMEOUT_SECONDS="${JOB_WAIT_TIMEOUT_SECONDS:-300}"

# MAX_CONCURRENT_JOBS: how many pending jobs this leader replica processes
# at once, instead of one at a time. Different Linode instances are
# independent of each other from Linode's API's point of view, and the
# etcd compare-and-swap on each job's pending->processing transition
# already makes concurrent claims safe - the old one-at-a-time loop was a
# control-loop limitation, not a correctness requirement. Keeping this
# bounded (rather than unlimited) avoids firing off a burst of concurrent
# shutdown/status-poll/boot cycles large enough to risk Linode API rate
# limiting during a large simultaneous scale-up.
MAX_CONCURRENT_JOBS="${MAX_CONCURRENT_JOBS:-5}"

LOCK_LEASE_TTL=30            # seconds; lock auto-expires if holder stops renewing
LOCK_KEEPALIVE_INTERVAL=10   # renew well before TTL expiry
LOCK_LEASE_ID=""
LOCK_KEEPALIVE_PID=""

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# ------------------------------------------------------------
# Select healthy etcd endpoint dynamically
# ------------------------------------------------------------
get_healthy_etcd() {
  IFS=',' read -ra EPS <<< "$ETCD_ENDPOINTS"
  for ep in "${EPS[@]}"; do
    if curl -fsS --max-time 2 "$ep/health" >/dev/null 2>&1; then
      echo "$ep"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------
# Lease helpers (back the leader lock with a TTL so a dead holder can never
# wedge it forever)
# ------------------------------------------------------------
grant_lease() {
  local EP="$1"
  local RESP
  RESP=$(curl -s -X POST "$EP/v3/lease/grant" \
    -H "Content-Type: application/json" \
    -d "{\"TTL\": $LOCK_LEASE_TTL}")
  echo "$RESP" | jq -r '.ID // empty'
}

revoke_lease() {
  local EP="$1"
  local LEASE_ID="$2"
  [[ -z "$LEASE_ID" ]] && return 0
  curl -s -X POST "$EP/v3/lease/revoke" \
    -H "Content-Type: application/json" \
    -d "{\"ID\": \"$LEASE_ID\"}" >/dev/null 2>&1 || true
}

keepalive_lease() {
  local EP="$1"
  local LEASE_ID="$2"
  while true; do
    sleep "$LOCK_KEEPALIVE_INTERVAL"
    curl -s -X POST "$EP/v3/lease/keepalive" \
      -H "Content-Type: application/json" \
      -d "{\"ID\": \"$LEASE_ID\"}" >/dev/null 2>&1 || true
  done
}

# ------------------------------------------------------------
# Acquire leader lock (multi-replica safe, lease-backed)
# ------------------------------------------------------------
acquire_lock() {
  local EP="$1"
  local RESPONSE

  LOCK_LEASE_ID="$(grant_lease "$EP")"
  if [[ -z "$LOCK_LEASE_ID" || "$LOCK_LEASE_ID" == "null" ]]; then
    log WARN "Failed to grant etcd lease for leader lock."
    LOCK_LEASE_ID=""
    return 1
  fi

  RESPONSE=$(curl -s -X POST "$EP/v3/kv/txn" \
    -H "Content-Type: application/json" \
    -d "{
      \"compare\": [{
        \"target\": \"CREATE\",
        \"key\": \"$(b64 "$LOCK_KEY")\",
        \"create_revision\": \"0\"
      }],
      \"success\": [{
        \"request_put\": {
          \"key\": \"$(b64 "$LOCK_KEY")\",
          \"value\": \"$(b64 "$POD_NAME")\",
          \"lease\": \"$LOCK_LEASE_ID\"
        }
      }],
      \"failure\": []
    }")

  if echo "$RESPONSE" | jq -e '.succeeded == true' >/dev/null 2>&1; then
    # Keep the lease alive in the background for as long as this process is
    # healthy. If this process dies for any reason without reaching
    # release_lock (crash, OOM-kill, eviction, SIGKILL), the lease simply
    # expires after LOCK_LEASE_TTL seconds with nothing left to renew it,
    # and the lock key is deleted automatically by etcd - no permanently
    # stuck lock.
    keepalive_lease "$EP" "$LOCK_LEASE_ID" &
    LOCK_KEEPALIVE_PID=$!
    return 0
  else
    # Didn't win the lock - revoke the lease we just granted rather than
    # leaving it to expire on its own uselessly.
    revoke_lease "$EP" "$LOCK_LEASE_ID"
    LOCK_LEASE_ID=""
    return 1
  fi
}

release_lock() {
  local EP="$1"

  if [[ -n "$LOCK_KEEPALIVE_PID" ]]; then
    kill "$LOCK_KEEPALIVE_PID" 2>/dev/null || true
    wait "$LOCK_KEEPALIVE_PID" 2>/dev/null || true
    LOCK_KEEPALIVE_PID=""
  fi

  if [[ -n "$LOCK_LEASE_ID" ]]; then
    # Revoking the lease atomically deletes every key attached to it
    # (our lock key) - simpler and more certain than a separate deleterange.
    revoke_lease "$EP" "$LOCK_LEASE_ID"
    LOCK_LEASE_ID=""
  else
    # Fallback safety net (shouldn't normally be reached).
    curl -s -X POST "$EP/v3/kv/deleterange" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"$(b64 "$LOCK_KEY")\"}" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------
# Prune WORKER_PIDS (background process_job PIDs launched by the main loop)
# down to just the ones still running. Deliberately never touches
# LOCK_KEEPALIVE_PID - see the main loop comment on why that PID must never
# be waited on via a bare `wait`/`wait -n`.
# ------------------------------------------------------------
prune_finished_workers() {
  local pid
  local -a still_running=()
  if (( ${#WORKER_PIDS[@]} > 0 )); then
    for pid in "${WORKER_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still_running+=("$pid")
      fi
    done
  fi
  WORKER_PIDS=("${still_running[@]}")
}

# ------------------------------------------------------------
# Wait for a Linode instance to reach a desired status, up to a timeout.
# Returns 0 if reached, 1 if the timeout elapsed first.
# ------------------------------------------------------------
wait_for_linode_status() {
  local id="$1" desired="$2" timeout="$3"
  local waited=0
  local st
  while true; do
    st=$(linode-cli linodes view "$id" --json | jq -r '.[0].status')
    [[ "$st" == "$desired" ]] && return 0
    if (( waited >= timeout )); then
      return 1
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
}

# ------------------------------------------------------------
# Fetch pending jobs
# ------------------------------------------------------------
get_jobs() {
  EP="$1"

  KEY=$(b64 "$PREFIX")
  RANGE_END=$(b64 "/vlan-config0")   # etcd range end: everything under the /vlan-config/ prefix

  curl -s -X POST "$EP/v3/kv/range" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$KEY\",\"range_end\":\"$RANGE_END\"}"
}

# ------------------------------------------------------------
# Update job status
# ------------------------------------------------------------
update_job_status() {
  EP="$1"
  KEY_RAW="$2"
  VALUE="$3"

  curl -s -X POST "$EP/v3/kv/put" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$(b64 "$KEY_RAW")\",\"value\":\"$(b64 "$VALUE")\"}" >/dev/null
}

# ------------------------------------------------------------
# Mark a job failed (used when a wait_for_linode_status call times out).
# Not auto-retried by this controller - see JOB_WAIT_TIMEOUT_SECONDS comment
# above for why that's safe (the DaemonSet pod's own restart loop resubmits
# a fresh pending job on its own for a genuinely transient failure).
# ------------------------------------------------------------
mark_job_failed() {
  local ep="$1" key_raw="$2" current_value="$3" reason="$4"
  local failed_value
  failed_value=$(echo "$current_value" | jq \
    --arg reason "$reason" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status = "failed" | .failure_reason = $reason | .failed_at = $ts')
  update_job_status "$ep" "$key_raw" "$failed_value"
}

# ------------------------------------------------------------
# Process single job
# ------------------------------------------------------------
process_job() {
  EP="$1"
  KEY_RAW="$2"
  VALUE_RAW="$3"

  LINODE_ID=$(echo "$VALUE_RAW" | jq -r '.linode_id')
  CONFIG_ID=$(echo "$VALUE_RAW" | jq -r '.current_config_id')
  INTERFACES=$(echo "$VALUE_RAW" | jq '.interfaces')

  if [[ -z "$LINODE_ID" || "$LINODE_ID" == "null" ]]; then
    log INFO "Invalid linode_id. Skipping."
    return
  fi

  if [[ -z "$CONFIG_ID" || "$CONFIG_ID" == "null" ]]; then
    log INFO "Invalid config_id. Skipping."
    return
  fi

  log INFO "Attempting to mark job $LINODE_ID as processing"

  # -------------------------------
  # Atomic pending → processing
  # -------------------------------
  # NOTE: compute the "processing" JSON as its own variable first, rather
  # than nesting a `jq '.status=\"processing\"'` filter directly inside this
  # already-double-quoted curl -d "..." string. That nesting doesn't survive
  # bash's quote handling - the backslashes reach jq intact instead of being
  # stripped, jq fails to compile, and the command substitution silently
  # returns empty. That empty value then got base64'd and written to etcd in
  # place of the real job, corrupting it (permanently, if the controller
  # were interrupted before reaching the later "completed" write, since an
  # empty status can never match "pending" again). Hoisting this out avoids
  # the nested-quoting entirely.
  PROCESSING_VALUE="$(echo "$VALUE_RAW" | jq '.status = "processing"')"
  if [[ -z "$PROCESSING_VALUE" ]]; then
    log ERROR "Failed to construct 'processing' status JSON for $LINODE_ID (jq error). Skipping this cycle."
    return 1
  fi
  PROCESSING_VALUE_B64="$(b64 "$PROCESSING_VALUE")"

  TXN_RESPONSE=$(curl -s -X POST "$EP/v3/kv/txn" \
    -H "Content-Type: application/json" \
    -d "{
      \"compare\": [{
        \"target\": \"VALUE\",
        \"key\": \"$(b64 "$KEY_RAW")\",
        \"value\": \"$(b64 "$VALUE_RAW")\"
      }],
      \"success\": [{
        \"request_put\": {
          \"key\": \"$(b64 "$KEY_RAW")\",
          \"value\": \"$PROCESSING_VALUE_B64\"
        }
      }],
      \"failure\": []
    }")

  if ! echo "$TXN_RESPONSE" | jq -e '.succeeded == true' >/dev/null 2>&1; then
    log INFO "Another controller already processing $LINODE_ID"
    return
  fi

  log INFO "Waiting up to ${JOB_WAIT_TIMEOUT_SECONDS}s for Linode $LINODE_ID to become offline"

  # ---------------------------------------
  # Wait until 02-script has shutdown node (bounded - see JOB_WAIT_TIMEOUT_SECONDS)
  # ---------------------------------------
  if ! wait_for_linode_status "$LINODE_ID" "offline" "$JOB_WAIT_TIMEOUT_SECONDS"; then
    log ERROR "Linode $LINODE_ID did not reach 'offline' within ${JOB_WAIT_TIMEOUT_SECONDS}s - giving up on this job so other queued nodes aren't blocked behind it. Marking failed; needs manual investigation (see docs/TROUBLESHOOTING.md). No config change was made to this instance."
    mark_job_failed "$EP" "$KEY_RAW" "$PROCESSING_VALUE" "timeout waiting for offline"
    return 1
  fi

  log INFO "Updating config $CONFIG_ID for Linode $LINODE_ID"

  linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" \
    --interfaces "$INTERFACES" >/dev/null

  log INFO "Booting Linode $LINODE_ID"

  linode-cli linodes boot "$LINODE_ID" --config "$CONFIG_ID" >/dev/null

  log INFO "Waiting up to ${JOB_WAIT_TIMEOUT_SECONDS}s for Linode $LINODE_ID to become running"

  # Bounded wait - see JOB_WAIT_TIMEOUT_SECONDS. Note the config change and
  # boot have already been issued by this point, so unlike the offline-wait
  # timeout above, giving up here does not mean nothing happened - it means
  # visibility/investigation is needed, not that it's safe to just retry
  # config-update/boot again blindly.
  if ! wait_for_linode_status "$LINODE_ID" "running" "$JOB_WAIT_TIMEOUT_SECONDS"; then
    log WARN "Linode $LINODE_ID did not reach 'running' within ${JOB_WAIT_TIMEOUT_SECONDS}s. Config change and boot were already issued - the node may still come up shortly on its own. Marking failed for visibility; needs manual verification (see docs/TROUBLESHOOTING.md)."
    mark_job_failed "$EP" "$KEY_RAW" "$PROCESSING_VALUE" "timeout waiting for running (config already applied, boot already triggered)"
    return 1
  fi

  # ---------------------------------------
  # Mark completed
  # ---------------------------------------
  FINAL_VALUE=$(echo "$VALUE_RAW" | jq '.status="completed"')

  curl -s -X POST "$EP/v3/kv/put" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$(b64 "$KEY_RAW")\",\"value\":\"$(b64 "$FINAL_VALUE")\"}" >/dev/null

  log INFO "Job completed for $LINODE_ID"
}

# ------------------------------------------------------------
# Test seam: lets tests/bash `source` this script and call its functions
# directly (e.g. b64, acquire_lock, process_job) without starting the main
# loop below, which talks to the real etcd/Linode APIs forever. Unset in
# every real deployment - the container always execs this script directly,
# never sources it - so this is a no-op there. See tests/README.md.
# ------------------------------------------------------------
if [[ "${SOURCE_ONLY_FOR_TESTS:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ============================================================
# Main Loop
# ============================================================

log INFO "Starting VLAN Config Controller (replica-safe). POD=$POD_NAME"
log INFO "ETCD_ENDPOINTS=$ETCD_ENDPOINTS"

# Best-effort cleanup on graceful termination (SIGTERM from a rollout/
# restart, or a normal script error). This is a courtesy - the lease TTL in
# acquire_lock/release_lock is the real guarantee for cases this can't run
# at all (SIGKILL, OOM-kill, node failure).
CURRENT_EP=""
cleanup_on_exit() {
  if [[ -n "$CURRENT_EP" ]]; then
    release_lock "$CURRENT_EP"
  fi
}
trap cleanup_on_exit EXIT INT TERM

while true; do

  EP=$(get_healthy_etcd || true)
  if [[ -z "${EP:-}" ]]; then
    log ERROR "No healthy etcd endpoint reachable. Retrying..."
    sleep 5
    continue
  fi
  CURRENT_EP="$EP"

  if ! acquire_lock "$EP"; then
    sleep 3
    continue
  fi

  RESPONSE=$(get_jobs "$EP")

  # NOTE: etcd's v3 JSON gateway omits the "count" field entirely (proto3
  # default-value omission) rather than sending "count":"0" when a range
  # query matches zero keys - so `.count` came back as jq's `null`, not the
  # string "0", and `[[ "$COUNT" == "0" ]]` never matched. That meant every
  # single idle poll (the common case) fell through to `jq -c '.kvs[]'` on a
  # response with no `.kvs` key at all, producing "Cannot iterate over null"
  # once per poll cycle. The `// "0"` / `// empty` fallbacks below handle a
  # missing field the same as an explicit zero/empty result.
  COUNT=$(echo "$RESPONSE" | jq -r '.count // "0"')

  if [[ "$COUNT" == "0" ]]; then
    release_lock "$EP"
    CURRENT_EP=""
    sleep 5
    continue
  fi

  # NOTE: process substitution (< <(...)) instead of piping into the while
  # loop - keeps the loop in the current shell rather than a subshell, and
  # combined with dropping `set -e` above, a single job's failure can no
  # longer take down the whole controller or leak the leader lock. A failed
  # job just stays pending/processing and gets retried on a later iteration
  # (by this replica or another).
  #
  # Jobs are launched in the background, up to MAX_CONCURRENT_JOBS at once,
  # rather than one at a time - see the MAX_CONCURRENT_JOBS comment near the
  # top of this file for why that's safe (per-job etcd CAS already prevents
  # double-processing regardless of how many run concurrently).
  #
  # IMPORTANT: acquire_lock already has its own background job running -
  # keepalive_lease, which loops forever until release_lock explicitly kills
  # it. A bare `wait` / `wait -n` / `jobs -rp` with no PID arguments would
  # count or block on THAT job too, and since it never exits on its own,
  # that would deadlock this controller on the very first job it ever
  # processes. So we track our own worker PIDs explicitly in WORKER_PIDS and
  # only ever throttle/wait on those specific PIDs, never on "all background
  # jobs of this shell."
  declare -a WORKER_PIDS=()

  while IFS= read -r ITEM; do
    KEY_RAW=$(echo "$ITEM" | jq -r '.key | @base64d')
    VALUE_RAW=$(echo "$ITEM" | jq -r '.value | @base64d')

    STATUS=$(echo "$VALUE_RAW" | jq -r '.status')

    if [[ "$STATUS" != "pending" ]]; then
      continue
    fi

    # Throttle: block here (on our own tracked worker PIDs only) until a
    # concurrency slot frees up.
    prune_finished_workers
    while (( ${#WORKER_PIDS[@]} >= MAX_CONCURRENT_JOBS )); do
      wait -n "${WORKER_PIDS[@]}" 2>/dev/null || true
      prune_finished_workers
    done

    (
      if ! process_job "$EP" "$KEY_RAW" "$VALUE_RAW"; then
        log WARN "process_job failed or timed out for a job - see prior log lines for which Linode ID and why."
      fi
    ) &
    WORKER_PIDS+=("$!")
  done < <(echo "$RESPONSE" | jq -c '.kvs[]? // empty')

  # Let every worker launched this cycle finish (by PID, never a bare
  # `wait`) before releasing the lock and starting the next poll.
  if (( ${#WORKER_PIDS[@]} > 0 )); then
    for pid in "${WORKER_PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi

  release_lock "$EP"
  CURRENT_EP=""
  sleep 3
done
