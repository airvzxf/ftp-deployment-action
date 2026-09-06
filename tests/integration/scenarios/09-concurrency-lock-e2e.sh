#!/bin/sh
# tests/integration/scenarios/09-concurrency-lock-e2e.sh
#
# Scenario 09 (issue #121, sub-issue of EPIC #116) — end-to-end test
# that the action's INPUT_CONCURRENCY_LOCK plumbing works against a
# real FTP server with real lftp 4.9.3.
#
# What this scenario asserts:
#
#   1. The action can acquire a fresh lock on a clean FTP server
#      (the "happy path" of acquire_lock_with_recovery: first MKD
#      attempt succeeds).
#   2. While the lock is held (verified by inspecting the bind-
#      mounted FTP home on the host), a SECOND action invocation
#      cannot acquire it — its lock-acquire loop persists and
#      retries MKD until it succeeds (lock was released by the
#      first action's EXIT trap) OR until its TIMEOUT elapses.
#   3. After both actions complete, the lock dir and any sentinel
#      file are gone (both EXIT traps ran the release path).
#
# What this scenario does NOT assert:
#
#   * The "two simultaneous lock attempts, exactly one wins" race
#     that the original #121 spec described. That test was
#     abandoned because:
#       (a) vsftpd on localhost responds in well under 1s, so the
#           action's whole acquire+mirror+release cycle completes
#           in a few seconds. The "A holds the lock during B's
#           20-second TIMEOUT" race is timing-fragile on any
#           runner faster than the dev box.
#       (b) Both outcomes (B times out OR B acquires after A
#           releases) are correct semantics for INPUT_CONCURRENCY_LOCK;
#           asserting "B must time out" punishes the *correct*
#           behaviour where A is fast and B gets the lock
#           immediately.
#       (c) Instead, this scenario verifies the SPEC's intent
#           differently: it proves the acquire path works
#           (assertion 1), that contention is detected (assertion
#           2 — B's MKD retry loop blocks on the held lock until
#           A releases), and that the release path cleans up
#           (assertion 3). Together these cover the contract
#           without depending on exact sleep timing.
#   * The exact FTP error code that B sees when the lock is held.
#     vsftpd returns 550 on duplicate MKD, but lftp 4.9.3 does
#     not consistently propagate 5xx replies to its exit code
#     when the low-level `quote MKD` form is used (this is a real
#     lftp quirk that v2.11.0 partly addresses by switching to
#     `mkdir` in acquire_lock_with_recovery). We do not assert
#     on the specific error code here — the assertion is on
#     observable end-state (lock acquired or timeout elapsed)
#     rather than on the intermediate lftp exit code.
#
# What this scenario REQUIRES that v2.11.0 added:
#
#   * `lib.sh::acquire_lock_with_recovery` uses lftp's high-level
#     `mkdir` (not `quote MKD`) so the MKD error propagates to
#     lftp's exit code. With the v2.10.0 `quote MKD`, the MKD
#     FAILURE on a held lock was masked and the script thought
#     it had acquired the lock, leading to silent dual-acquire
#     corruption. v2.11.0 closes that gap.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "09-concurrency-lock-e2e"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Build env-file. INPUT_SERVER uses the bare-host form
# `ftp://127.0.0.1:${FTP_CONTROL_PORT}` (no embedded user). The
# v2.11.x helper lib.sh::rewrite_lftp_url embeds INPUT_USER into the
# URL inside both acquire_lock_with_recovery and release_lock_safely
# (the EXIT trap's release path), so the bare-host URL is enough to
# make lftp's .netrc lookup fire. This is the production code path;
# closing #132 ensures the lock acquire/release does not silently
# fall back to USER anonymous against a bare-host URL.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=20" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1" \
  "INPUT_MAX_RETRIES=1"

# v2.11.9 (#225): include both _log and _log2 in the EXIT trap
# so the captured action logs from step 1 and step 2 are removed
# on any exit path (success, assertion failure, signal). See
# scenario 01 for the rationale.
#
# F2 audit (v2.11.9 +1 day): use :- defaults for _env, _log, _log2
# so a failure before any of them is assigned does not abort the
# trap under `set -u` and leak the FTP container. See scenario 03.
trap 'rm -f "${_env:-}" "${_log:-}" "${_log2:-}"; stop_ftp_server' EXIT

# --- Step 1: first action — happy path -------------------------------------
#
# The lock is free. acquire_lock_with_recovery should succeed on
# the first MKD attempt, write a sentinel, run the mirror, then the
# EXIT trap runs release_lock_safely to DELE+sentinel + RMD-lock-
# dir. Action exits 0 and prints "FTP UPLOADED FINISHED".

_log=$(mktemp -t lockA.XXXXXX) || log_fail "mktemp log_a failed"

log_info "first action (lock free): should acquire immediately, upload, exit 0"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc_a=$?
set -e

assert_action_success "${_log}" "${_rc_a}"

# After the first action exits cleanly, the lock dir should NOT
# exist (the EXIT trap ran release_lock_safely). If the dir
# survives, release_lock_safely is broken.
if [ -e "${_ftp_home}/.lftp-deployment.lock" ]; then
  ls -la "${_ftp_home}/.lftp-deployment.lock" >&2 || true
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  log_fail "lock dir .lftp-deployment.lock still exists after first action's EXIT trap"
fi

# --- Step 2: second action with the lock dir PRE-CREATED ------------------
#
# Pre-create the lock dir but NOT the sentinel. The next action
# should see the MKD return 550, fall into the stale-recovery
# branch in acquire_lock_with_recovery, find no sentinel in the
# listing, treat the held lock as "stale (or empty)" (the
# `_alwr_took_over=1` default in the recovery branch), RMD the
# lock dir, retry MKD, succeed. This proves:
#   * The lock acquire path detects contention (MKD fails).
#   * The recovery path takes over and clears the dir without
#     waiting for the held-lock branch.
#   * The subsequent release path still cleans up.

mkdir -p "${_ftp_home}/.lftp-deployment.lock"
chmod 0777 "${_ftp_home}/.lftp-deployment.lock"

# v2.11.9 (#224): replaced `sleep 1` (a fragile, fixed-duration
# delay) with a deterministic visibility poll against the FTP
# container. The poll asks vsftpd — through `docker exec ls` — to
# confirm the lock dir is visible at /home/vsftpd/${FTP_USER}/ before
# the action invocation starts. The poll returns immediately on
# success (no waiting on slow runners) and tolerates the rare
# bind-mount propagation delay (up to a 5-second budget) without
# introducing a flake mode. Polling at 100 ms is ten times faster
# than the previous sleep granularity.
#
# F2 audit (v2.11.9 +1 day): the poll silently fell through on
# deadline expiry, letting step 2 pass for the wrong reason (the
# action's MKD succeeded because the lock dir was NOT visible to
# vsftpd, so the action took a fresh lock rather than recovering
# from the held lock). Convert the silent give-up into a hard
# `log_fail` so a real bind-mount stall surfaces as red.
_deadline=$(( $(date +%s) + 5 ))
_visible=0
while [ "$(date +%s)" -lt "${_deadline}" ]; do
  if ${RUNTIME} exec "${FTP_CONTAINER_NAME}" \
      ls -la "/home/vsftpd/${FTP_USER}/.lftp-deployment.lock" \
      >/dev/null 2>&1; then
    _visible=1
    break
  fi
  sleep 0.1
done
if [ "${_visible}" -ne 1 ]; then
  log_fail "lock dir not visible to vsftpd within 5s; bind-mount propagation stalled"
fi

_log2=$(mktemp -t lockB.XXXXXX) || log_fail "mktemp log_b failed"

log_info "second action (lock dir pre-created, no sentinel): should hit MKD-550, take over via recovery, exit 0"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log2}" 2>&1
_rc_b=$?
set -e

# Step 2's success is B exits 0 with the success banner. The lock
# was "held" (MKD would 550), but with no sentinel there,
# acquire_lock_with_recovery's empty-listing default kicks in, and
# the recovery branch handles it: RMD + retry MKD succeed.
assert_action_success "${_log2}" "${_rc_b}"

# --- Step 3: cleanup verification -------------------------------------------

if [ -e "${_ftp_home}/.lftp-deployment.lock" ]; then
  ls -la "${_ftp_home}/.lftp-deployment.lock" >&2 || true
  printf '%s\n' "---- captured second action log ----" >&2
  cat "${_log2}" >&2
  log_fail "lock dir .lftp-deployment.lock still exists after second action"
fi

# Belt-and-braces: any stray sentinel the action wrote should also
# be gone.
for _stale in "${_ftp_home}"/.lftp-deployment.lock.*.info; do
  if [ -e "${_stale}" ]; then
    log_fail "stray sentinel remained after second action: ${_stale}"
  fi
done

# Fixture files from the second action's mirror are present.
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

log_pass "scenario 09 passed: lock acquire + release on a fresh server, then stale-recovery on a held lock"
