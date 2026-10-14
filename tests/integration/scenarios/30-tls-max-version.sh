#!/bin/sh
# shellcheck disable=SC2329  # trap handlers are invoked indirectly.
#
# tests/integration/scenarios/30-tls-max-version.sh
#
# #361: lftp 4.9.3 closes a TLS 1.3 data connection without reading
# the server's session tickets. The kernel then resets the connection,
# drops lftp's close_notify (and, on a real network, the tail of the
# file), and vsftpd replies "426 Failure reading network stream.".
# The action caps TLS at 1.2 by default (tls_max_version), and
# `tls_max_version: '1.3'` lifts the cap.
#
# The test server allows TLS 1.3 and logs "SSL version: TLSvX.Y" for
# every connection (debug_ssl=YES in self-signed-cert.sh), so the
# check reads the negotiated version instead of waiting for the race.
#
#   1. Default inputs: the upload succeeds and every connection is
#      TLSv1.2.
#   2. tls_max_version: '1.3': the connections are TLSv1.3. The upload
#      itself is not asserted: it is the #361 race.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"
# shellcheck source=tests/integration/lib/self-signed-cert.sh
. "${COMMON}/self-signed-cert.sh"

scenario_setup "30-tls-max-version"

_cert=$(generate_self_signed_cert)
start_ftps_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}" "${_cert}" "explicit"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}" "${FTP_VSFTPD_CONF:-}"; stop_ftp_server' EXIT

# run_action [TLS_MAX_VERSION] — one action run against the server;
# sets _rc. An empty argument leaves the input unset (the default).
run_action() {
  {
    printf 'INPUT_SERVER=ftp://%s@127.0.0.1:%s\n' "${FTP_USER}" "${FTP_CONTROL_PORT}"
    printf 'INPUT_USER=%s\n' "${FTP_USER}"
    printf 'INPUT_PASSWORD=%s\n' "${FTP_PASSWORD}"
    printf 'INPUT_LOCAL_DIR=/data\n'
    printf 'INPUT_REMOTE_DIR=/\n'
    printf 'INPUT_MAX_RETRIES=1\n'
    printf 'INPUT_NET_TIMEOUT=10s\n'
    printf 'INPUT_FTP_SSL_ALLOW=true\n'
    printf 'INPUT_SSL_VERIFY_CERTIFICATE=false\n'
    printf 'INPUT_SSL_CHECK_HOSTNAME=false\n'
    printf 'INPUT_LFTP_SETTINGS=set ftp:ssl-force true;set net:persist-retries 0;\n'
    if [ -n "${1:-}" ]; then
      printf 'INPUT_TLS_MAX_VERSION=%s\n' "$1"
    fi
  } > "${_env}"
  chmod 0600 "${_env}"
  set +e
  timeout 60 ${RUNTIME} run --rm \
      --network host \
      -v "${FIXTURES_DIR}:/data:ro" \
      --env-file "${_env}" \
      "${IMAGE}" > "${_log}" 2>&1
  _rc=$?
  set -e
}

# tls_versions — the distinct "TLSvX.Y" values vsftpd logged so far.
tls_versions() {
  ${RUNTIME} exec "${FTP_CONTAINER_NAME}" cat /var/log/vsftpd/vsftpd.log \
    | sed -n 's/.*"SSL version: \(TLSv[0-9.]*\),.*/\1/p' | sort -u | tr '\n' ' '
}

# --- 1. default: TLS 1.2 ------------------------------------------------------
log_info "run 1: default tls_max_version"
run_action ""
assert_action_success "${_log}" "${_rc}"
assert_present "${FTP_DATA_DIR}/${FTP_USER}" "index.html"
_v=$(tls_versions)
log_info "negotiated: ${_v}"
[ "${_v}" = "TLSv1.2 " ] \
  || log_fail "default run negotiated '${_v}', expected only TLSv1.2 (#361)"

# --- 2. tls_max_version: '1.3' ------------------------------------------------
${RUNTIME} exec "${FTP_CONTAINER_NAME}" sh -c ': > /var/log/vsftpd/vsftpd.log' \
  || log_fail "could not truncate the vsftpd log"
log_info "run 2: tls_max_version=1.3"
run_action "1.3"
_v=$(tls_versions)
log_info "negotiated: ${_v} (action exit ${_rc}; not asserted, see header)"
[ "${_v}" = "TLSv1.3 " ] \
  || log_fail "tls_max_version=1.3 negotiated '${_v}', expected only TLSv1.3"

assert_server_alive
log_pass "scenario 30 passed: TLS 1.2 by default, TLS 1.3 with tls_max_version=1.3"
exit 0
