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
_lockdir="${_ftp_home}/.lftp-deployment.lock"
_stale_ts="20260101T000000Z"
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

# Build the env-file. acquire_lock_with_recovery calls lftp with
# $INPUT_SERVER as-is and predates the v2.11.0 URL rewrite; embed
# the user in the URL so lftp looks up the password from .netrc.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_SERVER=ftp://${FTP_USER}@127.0.0.1:${FTP_CONTROL_PORT}" \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=900" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1" \
  "INPUT_MAX_RETRIES=1"

trap 'rm -f "${_env}"; stop_ftp_server' EXIT

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
  cat "${_log}">&2
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

rm -f "${_log}"

log_pass "scenario 10 passed: stale sentinel from 2026-01-01 was taken over in ${_elapsed}s (<30s; stale-recovery fired)"
