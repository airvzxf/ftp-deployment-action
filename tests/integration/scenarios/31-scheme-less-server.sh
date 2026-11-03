#!/bin/sh
# shellcheck disable=SC2329  # trap handlers are invoked indirectly.
#
# tests/integration/scenarios/31-scheme-less-server.sh
#
# The `server` input documents that a bare `host[:port]` means
# `ftp://`. rewrite_lftp_url (lib.sh) embeds the user only in a URL
# with a scheme and passes a scheme-less value to lftp unchanged, so
# this scenario checks that lftp still logs in with the user and the
# password from ~/.netrc for `host:port` and does not fall back to
# `USER anonymous` (FND-0007).
#
#   1. The test server refuses anonymous logins (an anonymous `ls`
#      fails with 530), so a successful upload cannot be anonymous.
#   2. INPUT_SERVER=127.0.0.1:<port>: the upload succeeds and the
#      files land in the user's home. (start_ftp_server sets
#      LOG_STDOUT=true and the image sends vsftpd's output to
#      /dev/null, so there is no login log to read.)
#   3. The same scheme-less value with concurrency_lock "true": the
#      lock is acquired and released (the lock calls go through
#      rewrite_lftp_url too) and the upload lands in remote_dir.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "31-scheme-less-server"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"
_server="127.0.0.1:${FTP_CONTROL_PORT}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
_script=$(mktemp -t lftp31.XXXXXX) || log_fail "mktemp script failed"
trap 'rm -f "${_env:-}" "${_log:-}" "${_script:-}"; stop_ftp_server' EXIT

# dump_and_fail MESSAGE — print the captured log, then fail.
dump_and_fail() {
  printf '%s\n' "---- captured log ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of log ----" >&2
  log_fail "$1"
}

# --- 1. anonymous is refused ---------------------------------------------
{
  printf '%s\n' "set net:max-retries 1"
  printf '%s\n' "set net:timeout 10s"
  printf '%s\n' "set ftp:ssl-allow false"
  printf '%s\n' "open ftp://127.0.0.1:${FTP_CONTROL_PORT}"
  printf '%s\n' "ls"
  printf '%s\n' "quit"
} > "${_script}"
chmod 0600 "${_script}"
if lftp_run_script "${_script}" "${_log}" 30; then
  dump_and_fail "anonymous ls succeeded; the test server must refuse anonymous logins"
fi
if ! grep -q '530' "${_log}"; then
  dump_and_fail "anonymous ls failed without a 530 reply"
fi
log_info "anonymous login refused: $(grep -m 1 '530' "${_log}")"

# run_scheme_less REMOTE_DIR [KEY=value ...] — one action run with the
# scheme-less INPUT_SERVER; sets _rc.
run_scheme_less() {
  _rsl_remote=$1
  shift
  {
    printf 'INPUT_SERVER=%s\n' "${_server}"
    printf 'INPUT_USER=%s\n' "${FTP_USER}"
    printf 'INPUT_PASSWORD=%s\n' "${FTP_PASSWORD}"
    printf 'INPUT_LOCAL_DIR=/data\n'
    printf 'INPUT_REMOTE_DIR=%s\n' "${_rsl_remote}"
    printf 'INPUT_MAX_RETRIES=1\n'
    printf 'INPUT_NET_TIMEOUT=10s\n'
    printf 'INPUT_DNS_FATAL_TIMEOUT=10s\n'
    printf 'INPUT_FTP_SSL_ALLOW=false\n'
    for _rsl_kv in "$@"; do
      printf '%s\n' "${_rsl_kv}"
    done
  } > "${_env}"
  chmod 0600 "${_env}"
  set +e
  timeout 90 ${RUNTIME} run --rm \
      --network host \
      -v "${FIXTURES_DIR}:/data:ro" \
      --env-file "${_env}" \
      "${IMAGE}" > "${_log}" 2>&1
  _rc=$?
  set -e
}

# --- 2. scheme-less host:port, no lock -------------------------------------
log_info "invoking action with INPUT_SERVER=${_server} (no scheme)"
run_scheme_less /
assert_action_success "${_log}" "${_rc}"
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"
log_info "upload landed in the home of ${FTP_USER}"

# --- 3. scheme-less host:port with concurrency_lock ------------------------
log_info "invoking action with INPUT_SERVER=${_server} (no scheme) and concurrency_lock true"
run_scheme_less /locked \
  "INPUT_CONCURRENCY_LOCK=true" \
  "INPUT_CONCURRENCY_LOCK_TIMEOUT=20" \
  "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1"
assert_action_success "${_log}" "${_rc}"
if ! grep -q 'Acquired concurrency lock' "${_log}"; then
  dump_and_fail "action did not print 'Acquired concurrency lock'"
fi
if [ -e "${_ftp_home}/.lftp-deployment.lock" ]; then
  ls -la "${_ftp_home}/.lftp-deployment.lock" >&2 || true
  dump_and_fail "lock dir .lftp-deployment.lock still exists after the run"
fi
assert_present "${_ftp_home}" "locked"
assert_present "${_ftp_home}/locked" "index.html"
assert_present "${_ftp_home}/locked" "assets"

log_pass "scenario 31 passed: scheme-less INPUT_SERVER=${_server} logs in as the user, with and without concurrency_lock"

exit 0
