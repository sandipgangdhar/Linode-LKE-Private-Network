#!/bin/bash
# 03-script-ip-allocate.sh
#
# NOTE: the shebang above must stay on line 1 - it only works as an
# interpreter directive if it's byte 0 of the file. This script is invoked
# via a bare path (`/tmp/03-script-ip-allocate.sh "$SUBNET"` in
# 02-script-vlan-attach.sh), not `bash /tmp/...sh`, so if the shebang isn't
# first, execve() sees no valid interpreter, bash falls back to running the
# file under /bin/sh, and on this project's Debian-based container image
# (manifests/Dockerfile, `FROM python:3.9`) /bin/sh is dash - whose `[ ]`
# does not understand `==` (only POSIX `=`) and errors with "unexpected
# operator". That would make the `[ "$HTTP_CODE" == "200" ]` check below
# always take the failure branch, breaking VLAN IP allocation outright.
# Confirmed by reproducing this exact fallback+failure locally before
# fixing it - see tests/static/test_shell_script_hygiene.py, which now
# guards against this regressing (also fixed here and in
# 04-script-ip-release.sh, which had the identical bug).
#
# This shell script handles IP address allocation by interacting with the VLAN
# Leader Manager's REST API. It requests an available IP from the specified subnet
# and logs the result.
# 
# -----------------------------------------------------
# Parameters:
# 
# 1. SUBNET              - The subnet from which IPs are allocated.
# 2. API_ENDPOINT        - The endpoint for IP allocation requests.
# 
# -----------------------------------------------------
# Usage:
# 
# - This script is executed during VLAN manager initialization or scale-up events.
# - It calls the API to request an available IP address.
# - If successful, the IP is logged and returned.
# 
# -----------------------------------------------------
# Best Practices:
# 
# - Ensure the API is reachable before executing the script.
# - Monitor logs for successful IP allocation or errors.
# - Handle API timeouts and unexpected responses gracefully.
# 
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
# 
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
# Exit on error
set -e
if [[ -z "$SUBNET" ]]; then
    echo "[ERROR] SUBNET is not defined. Exiting."
    exit 1
fi

# === Environment Variables ===
# API endpoint for IP allocation
API_ENDPOINT="http://vlan-ip-controller-service.kube-system.svc.cluster.local:8080/allocate"

# Subnet is passed as the first argument
SUBNET=$1

# === Function to Log Events ===
# This function logs events with timestamps for better traceability
#
# NOTE: these write to stderr (>&2), not stdout, deliberately. This script's
# ONLY stdout output is the allocated IP itself (see the `echo $ALLOCATED_IP`
# on success below) - callers invoke this script via command substitution
# (IP_ADDRESS=$(...)), which captures stdout only. If these log/error lines
# went to stdout too, they'd get mixed into that captured value along with
# the real IP, and on failure the caller would have no clean way to tell
# "here's the actual reason" from "here's noise" - which is exactly the bug
# this fixes (see docs/TROUBLESHOOTING.md and the caller in
# 02-script-vlan-attach.sh, which now separately captures this stderr and
# logs it on failure).
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
    exit 1
}

# === Retry tuning ===
# Previously this script made exactly one attempt: any transient failure
# (the vlan-ip-controller pod mid-rollout, a momentary DNS blip on the
# in-cluster service name, one lost packet) failed the entire node
# onboarding outright, even though a fresh request moments later would very
# likely have succeeded (the actual duplicate-IP guard is an atomic etcd
# CAS on the server side - see scripts/06-rest-api.py - so retrying here is
# safe, not just convenient). 404 (wrong service/namespace) and 400 (caller
# passed a malformed subnet) are not retried - retrying a request that is
# wrong by construction just delays reporting the real problem.
MAX_RETRIES="${IP_ALLOCATE_MAX_RETRIES:-3}"
BACKOFF_BASE_SECONDS="${IP_ALLOCATE_BACKOFF_BASE_SECONDS:-2}"

# === Main Logic ===
log "Starting IP allocation request..."

# === Validate the subnet is provided ===
# If the subnet is not passed as an argument, exit with an error
if [ -z "$SUBNET" ]; then
    error "No subnet provided for IP allocation."
fi
log "Subnet provided for allocation: $SUBNET"

attempt=1
while true; do
    log "Sending IP allocation request to API at $API_ENDPOINT for subnet $SUBNET (attempt $attempt/$MAX_RETRIES)..."

    # `|| true` matters here: curl returns a non-zero exit status on a hard
    # connection failure (DNS, refused, timeout) even with -w/-o, separately
    # from whatever HTTP_CODE it wrote out (typically "000" in that case).
    # Under this script's `set -e`, an unguarded `RESPONSE=$(curl ...)` would
    # abort the whole script right here on that first failure - before the
    # retry loop below ever got a chance to run - which would make the
    # retry logic in this script pure dead code on exactly the failure mode
    # it exists to handle.
    RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST "$API_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{\"subnet\": \"$SUBNET\"}") || true

    HTTP_CODE="${RESPONSE: -3}"
    RESPONSE_BODY=$(cat /tmp/response_body.txt 2>/dev/null || echo "")

    if [ "$HTTP_CODE" == "200" ]; then
        ALLOCATED_IP=$(echo "$RESPONSE_BODY" | jq -r '.allocated_ip')
        log "Successfully allocated IP: $ALLOCATED_IP"
        echo "$ALLOCATED_IP"
        exit 0
    fi

    # Not retryable - the request is wrong by construction, a fresh attempt
    # would fail the exact same way.
    case "$HTTP_CODE" in
        404)
            error "API endpoint not found. Service 'vlan-ip-controller-service' may not be running in namespace 'kube-system'."
            ;;
        400)
            error "Bad request. The subnet format is incorrect."
            ;;
    esac

    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
        case "$HTTP_CODE" in
            000)
                error "Cannot reach the API after $MAX_RETRIES attempts. Possible DNS issue or the service is down."
                ;;
            500)
                error "No IP addresses available in the provided subnet (or a transient server error) after $MAX_RETRIES attempts: $RESPONSE_BODY"
                ;;
            *)
                error "Unexpected error (HTTP $HTTP_CODE) from API after $MAX_RETRIES attempts: $RESPONSE_BODY"
                ;;
        esac
    fi

    wait_time=$((BACKOFF_BASE_SECONDS ** attempt))
    log "Allocation request failed (HTTP $HTTP_CODE), retrying in ${wait_time}s..."
    sleep "$wait_time"
    attempt=$((attempt + 1))
done
