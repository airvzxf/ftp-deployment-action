#!/bin/sh
# tests/integration/scenarios/12-acquire-vs-bare-host-url.sh
#
# Scenario 12 (closes #132) — end-to-end test that the action's
# `INPUT_CONCURRENCY_LOCK` path works against the production code
# path: a bare-host `INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT}`
# with no user embedded in the URL. Before the v2.11.x fix,
# acquire_lock_with_recovery passed `$INPUT_SERVER` straight to lftp
# without applying the v2.11.0 URL rewrite, so lftp 4.9.3 fell back
# to `USER anonymous` against a bare-host URL and the FTP server
# rejected with 530. The lock-acquire loop then spun until
# `INPUT_CONCURRENCY_LOCK_TIMEOUT` (60s in the issue's repro) and the
# deployment failed. This scenario exercises the production code
# path end-to-end and asserts the lock is acquired AND released
# against a bare-host URL.
#
# What this scenario asserts:
#
#   1. The action exits 0 — lock acquired + mirror finished.
#   2. The action log contains the "Acquired concurrency lock" banner
#      (proves the lock path took the rewritten-URL branch and
#      succeeded; if the lock acquire timed out, this line is
#      missing and the action exits with the timeout banner instead).
#   3. The action completed in well under 30 seconds (proves the
#      acquire did not spin on the timeout because of anonymous
#      fallback — the issue's repro hit a 60-second acquire timeout
#      before the fix).
#   4. The lock dir `.lftp-deployment.lock` is absent after the
#      EXIT trap (proves the release path also worked with the
#      rewritten URL — release_lock_safely embeds the user too, so
#      the EXIT trap's `run_lftp_lock_release` does not silently
#      fail to RMD the dir).
#   5. The mirror's fixture files are present (proves the mirror
#      itself ran end-to-end — the URL rewrite also affects the
#      main mirror call, so this is the integration-level smoke
#      for the rewrite in run_lftp_once against the bare-host URL).
#
# What this scenario does NOT assert:
#
#   * That the lock dir is present on the FTP server DURING the
#     action's run (assertion 4 only checks state AFTER the EXIT
#     trap; we do not race the action's release against an in-
#     progress lftp PUT because the harness cannot reliably pause
#     the action without docker-exec).
#   * That lftp received the user-embedded URL specifically — that
#     is the unit-level assertion in tests/unit/lock.bats. Here we
#     only assert the observable end-state.
#
# What this scenario REQUIRES:
#
#   * lib.sh::rewrite_lftp_url is in place (the v2.11.x helper
#     extracted from run_lftp_once).
#   * acquire_lock_with_recovery accepts a USER argument and applies
#     the rewrite to all four lftp call sites (MKD, PUT, LIST,
#     DELE+RMD).
#   * release_lock_safely accepts a USER argument and applies the
#     rewrite to its EXIT-trap lftp call.
#   * entrypoint.sh passes INPUT_USER to both call sites.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "12-acquire-vs-bare-host-url"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Build env-file with the bare-host INPUT_SERVER. The
# build_action_env_file helper already writes
# `INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT}` (no user) as
# its default, so we just have to pass the INPUT_CONCURRENCY_LOCK
# knobs. This is exactly the production code path that v2.11.x's
# rewrite_lftp_url helper is meant to make work.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=20" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1" \
  "INPUT_MAX_RETRIES=1"

# v2.11.9 (#225): _log is included in the trap so the captured
# action log is removed on any exit path, not just the success
# branch. See scenarios 01 / 03 for the rationale.
#
# F2 audit (v2.11.9 +1 day): use :- defaults for _env and _log so
# a failure before either is assigned does not abort the trap under
# `set -u` and leak the FTP container. See scenario 03.
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

_log=$(mktemp -t lock12.XXXXXX) || log_fail "mktemp log failed"

_t_start=$(date +%s)
log_info "invoking action with bare-host INPUT_SERVER + INPUT_CONCURRENCY_LOCK=true (should complete in <30s via rewritten URL)"
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

# Assertion 1: action exited 0 — lock acquired + mirror finished.
if [ "${_rc}" -ne 0 ]; then
  printf '%s\n' "---- captured action log (exit ${_rc}, elapsed=${_elapsed}s) ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of action log ----" >&2
  log_fail "action exited ${_rc}; expected 0 (lock acquired + mirror completed)"
fi

# Assertion 2: lock acquisition banner — proves the lock path took
# the rewritten-URL branch and succeeded (without the rewrite, the
# MKD would 530 and this line would be missing; the action would
# instead print the timeout banner and exit 1).
if ! grep -q 'Acquired concurrency lock' "${_log}"; then
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of action log ----" >&2
  log_fail "action did not print 'Acquired concurrency lock'; lock acquire path regressed (#132)"
fi

# Assertion 3: timing — must be well under 30 seconds. With
# INPUT_CONCURRENCY_LOCK_TIMEOUT=20, if the lock-acquire path had
# NOT taken the rewritten URL the action would spin on MKD for
# ~20 seconds and then fail with the timeout banner (the assertion
# 1 check would catch that as an exit-1 failure); we still assert
# timing here so a slow but eventually-successful acquire
# (regression where the rewrite silently no-ops) is also caught.
if [ "${_elapsed}" -ge 30 ]; then
  printf '%s\n' "---- captured action log (elapsed=${_elapsed}s) ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of action log ----" >&2
  log_fail "action took ${_elapsed}s (>=30); lock-acquire did not take the rewritten URL"
fi

# Assertion 4: success banner — the action ran the full mirror.
if ! grep -q 'FTP UPLOADED FINISHED' "${_log}"; then
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of action log ----" >&2
  log_fail "action did not print the FTP UPLOADED FINISHED banner"
fi

# Assertion 5: lock dir absent after EXIT trap — release_lock_safely
# also applies the URL rewrite (otherwise the EXIT trap's lftp call
# would silently fail to authenticate and the lock dir would
# survive on the FTP server).
if [ -e "${_ftp_home}/.lftp-deployment.lock" ]; then
  ls -la "${_ftp_home}/.lftp-deployment.lock" >&2 || true
  printf '%s\n' "---- captured action log ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of action log ----" >&2
  log_fail "lock dir .lftp-deployment.lock still exists after EXIT trap; release path regressed (#132)"
fi

# Belt-and-braces: any stray sentinel the action wrote should also
# be gone.
for _stale in "${_ftp_home}"/.lftp-deployment.lock.*.info; do
  if [ -e "${_stale}" ]; then
    log_fail "stray sentinel remained after action: ${_stale}"
  fi
done

# Assertion 6: fixture files are present (the main mirror ran
# end-to-end, which proves the rewrite also fired inside
# run_lftp_once against the bare-host URL).
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

# _log cleanup is handled by the EXIT trap installed above
# (v2.11.9 #225).

log_pass "scenario 12 passed: bare-host INPUT_SERVER + concurrency_lock acquired + released in ${_elapsed}s (URL rewrite applied to both paths, closes #132)"
