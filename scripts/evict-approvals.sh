#!/usr/bin/env bash
# =============================================================================
# evict-approvals.sh — Operator cron for the v3 approval cache janitor.
#
# Sprint 2 · Task 01 (see tasking/sprint-2-operator-tooling/01-eviction-cron-
# script.md). This is pure glue: it loops the canister endpoint
# `evictExpiredApprovals(maxBatch : nat) -> (nat)` (defined in
# `src/backend/main.mo`, Candid declared in `src/backend/backend.did`) until
# the canister reports zero deletions for one pass, or until a hard iteration
# cap is reached.
#
# Design contract (do not break):
#   • The canister does no eviction on its own. This script owns the cadence.
#   • The endpoint is controller-gated. Failure paths must surface loudly.
#   • Total work per run is bounded by HAVEN_AOL_MAX_ITERATIONS × HAVEN_AOL_BATCH
#     so a single cron tick cannot burn through cycles.
#   • The script is idempotent: running it twice in a row is harmless.
#
# Environment variables (all optional except where noted):
#   HAVEN_AOL_CANISTER_ID    Canister id. Default: dciac-uaaaa-aaaad-qlzuq-cai
#                            (mainnet backend per docs/mainnet-icp-deploy-
#                            test-runbook.md §6).
#   HAVEN_AOL_NETWORK        Network passed to the CLI via `-e`. Default: ic.
#                            Use `local` against a `dfx start` / `icp start`
#                            replica for testing.
#   HAVEN_AOL_IDENTITY       Identity name passed via `--identity`. If unset,
#                            the CLI's currently selected default is used —
#                            note that on mainnet this MUST be a controller.
#   HAVEN_AOL_BATCH          maxBatch argument per call. Default: 500.
#                            500 stays well inside an update-message
#                            instruction budget (each evicted row is one
#                            HashMap delete + counter bump).
#   HAVEN_AOL_MAX_ITERATIONS Hard cap on loop passes per run. Default: 100.
#                            With the default batch this bounds one cron tick
#                            to at most 50,000 deletions.
#   HAVEN_AOL_CLI            Canister CLI binary. Default: icp (per project
#                            runbook). Override to `dfx` if your environment
#                            uses it.
#
# Flags:
#   --dry-run                Call the endpoint with maxBatch=0, which the
#                            canister treats as a no-op fast path (verified
#                            against src/backend/main.mo:2154). Reports the
#                            endpoint round-trip but mutates nothing.
#   -h | --help              Print this header and exit 0.
#
# Exit codes:
#   0  Steady state reached — cache fully drained or already empty.
#   1  Argument / environment error (bad flag, missing CLI).
#   2  Underlying CLI call failed (controller mismatch, network outage,
#      canister trap, etc.). The CLI's stderr is propagated.
#   3  Iteration cap (HAVEN_AOL_MAX_ITERATIONS) reached before the canister
#      reported zero. Cache is still growing faster than this script drains
#      it, or one batch is too small. Investigate before next tick.
#
# Incident response: see `docs/mainnet-icp-deploy-test-runbook.md` section
# "v3 Approval Cache Eviction".
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults and argument parsing
# -----------------------------------------------------------------------------

HAVEN_AOL_CANISTER_ID="${HAVEN_AOL_CANISTER_ID:-dciac-uaaaa-aaaad-qlzuq-cai}"
HAVEN_AOL_NETWORK="${HAVEN_AOL_NETWORK:-ic}"
HAVEN_AOL_IDENTITY="${HAVEN_AOL_IDENTITY:-}"
HAVEN_AOL_BATCH="${HAVEN_AOL_BATCH:-500}"
HAVEN_AOL_MAX_ITERATIONS="${HAVEN_AOL_MAX_ITERATIONS:-100}"
HAVEN_AOL_CLI="${HAVEN_AOL_CLI:-icp}"

DRY_RUN=0

usage() {
  # Print the script header (the first big banner comment) to stdout.
  sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "evict-approvals.sh: unknown argument: $1" >&2
      echo "Try --help." >&2
      exit 1
      ;;
  esac
done

# Numeric sanity on the env-supplied integers — guard against typos like
# "HAVEN_AOL_BATCH=five" causing the loop to spin in confusing ways.
case "${HAVEN_AOL_BATCH}" in
  ''|*[!0-9]*)
    echo "evict-approvals.sh: HAVEN_AOL_BATCH must be a non-negative integer, got: ${HAVEN_AOL_BATCH}" >&2
    exit 1
    ;;
esac
case "${HAVEN_AOL_MAX_ITERATIONS}" in
  ''|*[!0-9]*)
    echo "evict-approvals.sh: HAVEN_AOL_MAX_ITERATIONS must be a non-negative integer, got: ${HAVEN_AOL_MAX_ITERATIONS}" >&2
    exit 1
    ;;
esac

# Verify CLI is on PATH before we start logging — fail-fast.
if ! command -v "${HAVEN_AOL_CLI}" >/dev/null 2>&1; then
  echo "evict-approvals.sh: canister CLI '${HAVEN_AOL_CLI}' not on PATH" >&2
  echo "  Set HAVEN_AOL_CLI=dfx (or another path) if you use a different CLI." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

ts() {
  # ISO-8601 UTC timestamp, no fractional seconds — scrape-friendly.
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Build the CLI invocation. We use an array so identity is omitted cleanly
# when unset (CLI then uses its current default).
build_call_argv() {
  local batch="$1"
  local -a argv
  argv=(
    "${HAVEN_AOL_CLI}"
    canister
    call
    "${HAVEN_AOL_CANISTER_ID}"
    evictExpiredApprovals
    "(${batch} : nat)"
    -e "${HAVEN_AOL_NETWORK}"
  )
  if [ -n "${HAVEN_AOL_IDENTITY}" ]; then
    argv+=(--identity "${HAVEN_AOL_IDENTITY}")
  fi
  # Echo argv one element per line so the caller can read it via mapfile.
  printf '%s\n' "${argv[@]}"
}

# Parse the canister response, which looks like:
#   (42 : nat)
# Output: just the integer. Trap on anything else.
parse_count() {
  local raw="$1"
  # Strip whitespace, parens, and the ": nat" suffix.
  local cleaned
  cleaned="$(
    printf '%s' "${raw}" \
      | tr -d '() \t\n\r' \
      | sed -e 's/:nat$//' -e 's/_//g'
  )"
  case "${cleaned}" in
    ''|*[!0-9]*)
      echo "evict-approvals.sh: could not parse deletion count from canister response:" >&2
      printf '  raw: %s\n' "${raw}" >&2
      return 1
      ;;
  esac
  printf '%s' "${cleaned}"
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

START_TS="$(ts)"
echo "evict-approvals.sh: start ${START_TS}"
echo "  canister:        ${HAVEN_AOL_CANISTER_ID}"
echo "  network:         ${HAVEN_AOL_NETWORK}"
echo "  identity:        ${HAVEN_AOL_IDENTITY:-<cli default>}"
echo "  cli:             ${HAVEN_AOL_CLI}"
echo "  batch:           ${HAVEN_AOL_BATCH}"
echo "  max iterations:  ${HAVEN_AOL_MAX_ITERATIONS}"
echo "  dry-run:         ${DRY_RUN}"

if [ "${DRY_RUN}" -eq 1 ]; then
  # maxBatch=0 is the canister's no-op fast path. Confirms reachability +
  # auth without mutating state. See src/backend/main.mo:2154.
  echo "[$(ts)] dry-run: calling evictExpiredApprovals(0)"
  mapfile -t DRY_ARGV < <(build_call_argv 0)
  if ! DRY_OUT="$("${DRY_ARGV[@]}" 2>&1)"; then
    echo "${DRY_OUT}" >&2
    echo "evict-approvals.sh: dry-run CLI call failed" >&2
    exit 2
  fi
  DRY_COUNT="$(parse_count "${DRY_OUT}")" || exit 2
  if [ "${DRY_COUNT}" != "0" ]; then
    echo "evict-approvals.sh: dry-run expected 0 deletions, got ${DRY_COUNT}" >&2
    exit 2
  fi
  echo "[$(ts)] dry-run: reachable, controller-authorized, zero mutations"
  END_TS="$(ts)"
  echo "evict-approvals.sh: end ${END_TS} (dry-run)"
  exit 0
fi

TOTAL_DELETED=0
ITER=0
while [ "${ITER}" -lt "${HAVEN_AOL_MAX_ITERATIONS}" ]; do
  ITER=$((ITER + 1))
  mapfile -t CALL_ARGV < <(build_call_argv "${HAVEN_AOL_BATCH}")
  if ! CALL_OUT="$("${CALL_ARGV[@]}" 2>&1)"; then
    echo "${CALL_OUT}" >&2
    echo "evict-approvals.sh: iteration ${ITER} CLI call failed" >&2
    exit 2
  fi
  COUNT="$(parse_count "${CALL_OUT}")" || exit 2
  TOTAL_DELETED=$((TOTAL_DELETED + COUNT))
  echo "[$(ts)] iter=${ITER} deleted=${COUNT} cumulative=${TOTAL_DELETED}"
  if [ "${COUNT}" = "0" ]; then
    END_TS="$(ts)"
    echo "evict-approvals.sh: steady state reached"
    echo "evict-approvals.sh: total deleted: ${TOTAL_DELETED}"
    echo "evict-approvals.sh: end ${END_TS}"
    exit 0
  fi
done

# Iteration cap hit without seeing a zero — the cache is growing faster than
# we drain it, or HAVEN_AOL_BATCH is too small. Alert.
END_TS="$(ts)"
echo "evict-approvals.sh: HIT ITERATION CAP (${HAVEN_AOL_MAX_ITERATIONS}) — cache not drained" >&2
echo "evict-approvals.sh: total deleted: ${TOTAL_DELETED}" >&2
echo "evict-approvals.sh: end ${END_TS}" >&2
exit 3
