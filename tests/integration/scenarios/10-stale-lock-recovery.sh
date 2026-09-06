#!/bin/sh
# tests/integration/scenarios/10-stale-lock-recovery.sh
#
# Scenario 10 (issue #121, sub-issue of EPIC #116) — end-to-end test
# for the stale-lock AUTO-RECOVERY path in INPUT_CONCURRENCY_LOCK
# (added in v2.9.0). Closes the residual risk documented in the
# README from the v2.8.0 release: "if the holder dies before RMD,
# subsequent runs will wait until concurrency_lock_timeout and then
# fail with exit 1".
#
# Pre-creates the lock dir AND a sentinel file with a deliberately
# OLD timestamp (2026-01-01), then invokes the action with a HIGH
# timeout (900 seconds). The only way the action can complete in
# under 30 seconds is by taking over the stale lock via the
# acquire_lock_with_recovery path: list the FTP root, parse the
# sentinel, observe its age is well over INPUT_CONCURRENCY_LOCK_TIMEOUT
# (so the previous holder is treated as dead), DELE the sentinel +
# RMD the lock dir, then immediately retry MKD. If the
# stale-recovery code path regresses, the action will spin on MKD
# until its 900-second timeout expires — the timing assertion below
# catches that.
#
# What this scenario asserts:
#   1. The action exits 0 — stale-recovery successfully took over.
#   2. The action log shows the lock was acquired (banner).
#   3. The action completed in <30 seconds (vs the 900-second
#      configured timeout — proves the stale-recovery fired
#      instead of waiting for the timeout to expire).
#   4. The lock dir no longer exists (RMD ran as part of stale-
#      recovery AND again on the EXIT trap).
#   5. The fixture files are present on the server (the action
#      completed its mirror after taking over).
#
# What this scenario does NOT assert:
#
#   * That the pre-created stale sentinel is DELE'd at the FTP
#     server. v2.9.0's recovery path runs `quote DELE
#     ${stale_sentinel}`; whether vsftpd removes the file on
#     this code path depends on a `quote`-level FTP command
#     propagating 250/550 to lftp's exit code, which is brittle
#     for various lftp versions. The sentinel being orphaned
#     is bounded by the stale-recovery taking over (the lock IS
#     acquired) and the EXIT trap's release of the NEW sentinel
#     (the lock is released cleanly). So the next deployment
#     can re-claim the lock; an orphan sentinel from 30 days ago
#     is not actionable until the next holder's MKD fails AND
#     the recovery branch finds it via LIST + parse. The recovery
#     branch's empty-listing default (`_alwr_took_over=1`) means
#     even an orphaned sentinel that the listing didn't return
#     does not block acquisition. The orphan is a hygiene
#     issue that would naturally clear on the NEXT stale-recovery
#     event that successfully lists. It is NOT a correctness
#     issue for this release. The next round of FTP-integration
#     work (#120 FTPS coverage) can add a deep-cleanup pass that
#     iterates parsed sentinel names and DELE's each one before
#     returning to the MKD loop; that is a follow-up.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "10-stale-lock-recovery"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Pre-create the lock dir and a stale sentinel. The harness creates
# these on the host bind-mount; vsftpd (inside the container) sees
# them as part of the FTP user's home.
#
# Layout matches what acquire_lock_with_recovery writes on a
# successful acquire (see lib.sh::_lock_sentinel_name):
#
#   FTP user home /
#   ├── .lftp-deployment.lock/                       (lock dir; lock lives here)
#   └── .lftp-deployment.lock.<STAMP>.<PID>.info     (sentinel; sibling of lock dir)
#
# Permissions: chmod 0777 so the in-container ftp user can RMD the
# lock dir during recovery (vsftpd creates it as ftp:ftp but the
# bind-mount maps ownership to host; 0777 ensures RMD succeeds
# regardless).
#
# v2.11.9 (#229): the sentinel timestamp was hardcoded to
# "20260101T000000Z" (a date clearly in the past) so the
# action's stale-recovery branch could prove the takeover fired.
# On a long-lived CI runner where the system date drifts past the
# fixed stamp, the comparison INPUT_CONCURRENCY_LOCK_TIMEOUT vs
# (now − _stale_ts) can fail or behave inconsistently; the test
# is also brittle to whoever happens to be reading the spec in
# the future (2026 is "in the past" today but ambiguous in 2030).
# Make the stamp dynamic: subtract the desired staleness window
# from the current UTC time so the sentinel is exactly
# (2 × INPUT_CONCURRENCY_LOCK_TIMEOUT) older than the action's
# threshold. The sentinel is then guaranteed stale by construction,
# independent of the runner's wall clock. POSIX-awk does the date
# arithmetic; no GNU date dependency.
#
# F2 audit (v2.11.9 +1 day): the staleness window is derived from
# the same _tlock_timeout variable that is passed to the env file,
# so changing one changes the other. The previous shape hardcoded
# 900 in two unrelated places (the awk now_offset argument and
# INPUT_CONCURRENCY_LOCK_TIMEOUT); a future tweak to one would
# silently break the (2× threshold) invariant the test asserts.
_tlock_timeout=900
_lockdir="${_ftp_home}/.lftp-deployment.lock"
_stale_ts=$(awk -v now_offset="$(( 2 * _tlock_timeout ))" 'BEGIN {
  "date -u +%s" | getline now
  close("date -u +%s")
  ts = now - now_offset
  printf "%04d%02d%02dT%02d%02d%02dZ", \
    strftime("%Y", ts), strftime("%m", ts), strftime("%d", ts), \
    strftime("%H", ts), strftime("%M", ts), strftime("%S", ts)
}')
_stale_pid="99999"
_stale_sentinel=".lftp-deployment.lock.${_stale_ts}.${_stale_pid}.info"

mkdir -p "${_lockdir}"
chmod 0777 "${_lockdir}"

{
  printf 'pid=%s\n' "${_stale_pid}"
  printf 'started_at=%s\n' "${_stale_ts}"
  printf 'host=stale-holder-from-scenario-10\n'
} > "${_ftp_home}/${_stale_sentinel}"

assert_present "${_ftp_home}" ".lftp-deployment.lock"
assert_present "${_ftp_home}" "${_stale_sentinel}"

# Build the env-file. INPUT_SERVER uses the bare-host form
# `ftp://127.0.0.1:${FTP_CONTROL_PORT}` (no embedded user). The
# v2.11.x helper lib.sh::rewrite_lftp_url embeds INPUT_USER into
# the URL inside both acquire_lock_with_recovery and
# release_lock_safely (the EXIT trap's release path), so the bare-
# host URL is enough to make lftp's .netrc lookup fire. This is the
# production code path; closing #132 ensures the stale-recovery
# branch's LIST/DELE/RMD/MKD lftp calls do not silently fall back
# to USER anonymous against a bare-host URL.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=${_tlock_timeout}" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1" \
  "INPUT_MAX_RETRIES=1"

# v2.11.9 (#225): include _log in the EXIT trap so the captured
# action log is removed on any exit path (success, assertion
# failure, signal). See scenario 01 for the rationale.
#
# F2 audit (v2.11.9 +1 day): use :- defaults for _env and _log so
# a failure before either is assigned does not abort the trap under
# `set -u` and leak the FTP container. See scenario 03.
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

_log=$(mktemp -t lock10.XXXXXX) || log_fail "mktemp log failed"

_t_start=$(date +%s)
log_info "invoking action with stale sentinel pre-created (TIMEOUT=900; should complete in <30s via stale-recovery)"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
_t_end=$(date +%s)
_elapsed=$((_t_end - _t_start))

log_info "action completed in ${_elapsed}s with rc=${_rc}"

# Assertion 1: action exited 0 — stale-recovery took over.
if [ "${_rc}" -ne 0 ]; then
  printf '%s\n' "---- captured action log (exit ${_rc}, elapsed=${_elapsed}s) ----" >&2
  cat "${_log}" >&2
  log_fail "action exited ${_rc}; expected 0 via stale-recovery"
fi

# Assertion 2: success banner — the action ran the full mirror.
if ! grep -q 'FTP UPLOADED FINISHED' "${_log}"; then
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  log_fail "action did not print the FTP UPLOADED FINISHED banner"
fi

# Assertion 3: lock acquisition logged — proves the recovery branch
# returned 0 (either first-try acquire or stale-recovery; timing
# distinguishes them).
if ! grep -q 'Acquired concurrency lock' "${_log}"; then
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  log_fail "action did not print 'Acquired concurrency lock'"
fi

# Assertion 4: timing — must be <30 seconds. With TIMEOUT=900, if
# stale-recovery had NOT fired, the action would have polled for
# 900 seconds before timing out. The fact that it finished in
# <30s is direct evidence that the recovery path detected the
# stale sentinel (or treated the empty listing as stale) and
# DELE+RMD ran on the first MKD failure (well within budget).
if [ "${_elapsed}" -ge 30 ]; then
  printf '%s\n' "---- captured action log (elapsed=${_elapsed}s) ----" >&2
  cat "${_log}" >&2
  log_fail "action took ${_elapsed}s (>=30); stale-recovery did NOT take over"
fi

# Assertion 5: lock dir no longer exists — RMD ran as part of
# recovery AND the EXIT trap released whatever the recovery
# wrote.
if [ -e "${_ftp_home}/.lftp-deployment.lock" ]; then
  ls -la "${_ftp_home}/.lftp-deployment.lock" >&2 || true
  log_fail "lock dir .lftp-deployment.lock still exists after action"
fi

# Assertion 6: fixture files are present.
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

log_pass "scenario 10 passed: stale sentinel from ${_stale_ts} was taken over in ${_elapsed}s (<30s; stale-recovery fired)"
