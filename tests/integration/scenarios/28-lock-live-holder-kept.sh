#!/bin/sh
# tests/integration/scenarios/28-lock-live-holder-kept.sh
#
# Scenario 28 (#250) — a holder whose sentinel is older than
# concurrency_lock_timeout but younger than 6 h is still alive (a
# long mirror), so the waiter must give up after its timeout instead
# of taking the lock over.
#
# What this scenario asserts:
#   1. The action exits 1 within ~15 s (timeout 5 s, poll 1 s).
#   2. The error names the holder's sentinel and how to clear it.
#   3. The lock dir and the sentinel are still on the server.
#   4. Nothing was uploaded.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "28-lock-live-holder-kept"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Sentinel stamped 60 s ago: older than the 5 s timeout below, far
# younger than the 6 h after which a holder is presumed dead.
_live_ts=$(awk 'BEGIN {
  "date -u +%s" | getline now
  close("date -u +%s")
  ts = now - 60
  printf "%s", strftime("%Y%m%dT%H%M%SZ", ts, 1)
}')
_live_sentinel=".lftp-deployment.lock.${_live_ts}.4242.info"

mkdir -p "${_ftp_home}/.lftp-deployment.lock"
chmod 0777 "${_ftp_home}/.lftp-deployment.lock"
printf 'pid=4242\nstarted_at=%s\nhost=live-holder-scenario-28\n' "${_live_ts}" \
  > "${_ftp_home}/${_live_sentinel}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=5" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1"

trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

_log=$(mktemp -t lock28.XXXXXX) || log_fail "mktemp log failed"

_t_start=$(date +%s)
log_info "invoking action against a live holder (sentinel ${_live_ts}, TIMEOUT=5)"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
_elapsed=$(( $(date +%s) - _t_start ))
log_info "action completed in ${_elapsed}s with rc=${_rc}"

_dump_log() {
  printf '%s\n' "---- captured action log (exit ${_rc}, elapsed=${_elapsed}s) ----" >&2
  cat "${_log}" >&2
}

if [ "${_rc}" -ne 1 ]; then
  _dump_log
  log_fail "action exited ${_rc}; expected 1 (lock held by a live run)"
fi

if [ "${_elapsed}" -ge 30 ]; then
  _dump_log
  log_fail "action took ${_elapsed}s (>=30); expected to give up after the 5 s timeout"
fi

if ! grep -q "is held by ${_live_sentinel}" "${_log}"; then
  _dump_log
  log_fail "error does not name the holder's sentinel ${_live_sentinel}"
fi

if ! grep -q "delete .lftp-deployment.lock and ${_live_sentinel} on the server" "${_log}"; then
  _dump_log
  log_fail "error does not say how to clear the lock"
fi

assert_present "${_ftp_home}" ".lftp-deployment.lock"
assert_present "${_ftp_home}" "${_live_sentinel}"
assert_absent "${_ftp_home}" "index.html"
assert_absent "${_ftp_home}" "about.html"
assert_absent "${_ftp_home}" "assets"

log_pass "scenario 28 passed: live holder (${_live_sentinel}) kept the lock; waiter gave up in ${_elapsed}s"
