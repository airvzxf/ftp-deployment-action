#!/bin/sh
# tests/integration/scenarios/03-ftps-explicit-upload.sh
#
# Scenario 03 (variant C, closes #120 half 1): explicit FTPS upload.
#
#   * Boots docker.io/fauria/vsftpd with SSL/TLS enabled (a custom
#     vsftpd.conf is bind-mounted in, with ssl_enable=YES and the
#     self-signed cert mounted at /etc/vsftpd/vsftpd.pem).
#   * Generates an ephemeral self-signed cert (see
#     tests/integration/lib/self-signed-cert.sh). The cert is
#     rsa:2048 / 1-day / CN=localhost; the action does not verify
#     it (INPUT_SSL_VERIFY_CERTIFICATE=false, INPUT_SSL_CHECK_HOSTNAME=
#     false) so a self-signed cert is sufficient.
#   * Invokes the ftp-deployment-action image end-to-end with
#     INPUT_SERVER=ftp://ftptest@127.0.0.1:2121. The user is
#     embedded in the URL — acquire_lock_with_recovery (which
#     forks its own lftp without applying run_lftp_once's URL
#     rewrite) then sees a user, lftp's NetRC::LookupHost fires,
#     and the password is read from .netrc (B-03). This is the
#     same workaround scenario 09 uses for the same reason.
#   * INPUT_FTP_SSL_ALLOW=true drives an AUTH TLS upgrade on the
#     control channel (the defining property of "explicit" FTPS).
#   * Asserts the action exits 0 AND emits `FTP UPLOADED FINISHED`
#     AND the fixture entries (index.html, about.html) are present
#     in the FTP user's home on the server, observed through the
#     bind-mounted data directory.
#
# Why this is variant C (action is the subject, not an alpine+lftp
# driver): variant B drove lftp directly from an alpine container
# and bypassed the .netrc plumbing entirely, so it could not
# exercise the AUTH TLS upgrade the action actually performs.
# v2.11.0 closed #124 (URL rewrite in run_lftp_once) and #111
# (HOME pinning), so the action can now talk to a real FTP server
# end-to-end — and that includes a real FTPS server. Scenarios 03
# and 04 are the integration-level proof.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"
# shellcheck source=tests/integration/lib/self-signed-cert.sh
. "${COMMON}/self-signed-cert.sh"

scenario_setup "03-ftps-explicit-upload"

# --- Step 1: cert + server ---------------------------------------------------
# generate_self_signed_cert prints the absolute path on stdout and
# is idempotent (reuses the cached cert on subsequent runs).
_cert=$(generate_self_signed_cert)
log_info "using cert ${_cert}"

# MODE="explicit" maps host port 2121 -> container port 21, with
# ssl_enable=YES (AUTH TLS upgrade on the control channel).
start_ftps_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}" "${_cert}" "explicit"

# --- Step 2: env-file --------------------------------------------------------
#
# Critical inputs:
#   * INPUT_SERVER carries the user. Two reasons:
#       (1) acquire_lock_with_recovery forks its own lftp without
#           the URL rewrite run_lftp_once applies; that lftp needs
#           a user in the URL to trigger its .netrc lookup. See
#           scenarios 08/09 for the same pattern.
#       (2) The main mirror lftp is fine either way (the rewrite
#           is a no-op when the URL already has a user).
#   * INPUT_FTP_SSL_ALLOW=true + INPUT_LFTP_SETTINGS with
#     `set ftp:ssl-force true;`: lftp 4.9.3 (pinned in the action
#     image) only triggers the AUTH TLS upgrade when ftp:ssl-force
#     is also set; ftp:ssl-allow alone permits SSL but does not
#     initiate it on a plain `ftp://` URL. This is the documented
#     lftp behaviour — see the spec for scenario 03 in
#     tests/integration/README.md.
#   * INPUT_SSL_VERIFY_CERTIFICATE=false / INPUT_SSL_CHECK_HOSTNAME=
#     false: the cert is self-signed and says CN=localhost but the
#     action connects to 127.0.0.1, so neither check can pass on
#     this cert. The action still negotiates TLS (the wire IS
#     encrypted); we only relax the post-handshake identity checks.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
trap 'rm -f "${_env}"; stop_ftp_server' EXIT

{
  printf 'INPUT_SERVER=ftp://%s@127.0.0.1:%s\n' "${FTP_USER}" "${FTP_CONTROL_PORT}"
  printf 'INPUT_USER=%s\n' "${FTP_USER}"
  printf 'INPUT_PASSWORD=%s\n' "${FTP_PASSWORD}"
  printf 'INPUT_LOCAL_DIR=/data\n'
  printf 'INPUT_REMOTE_DIR=/\n'
  printf 'INPUT_MAX_RETRIES=1\n'
  printf 'INPUT_NET_TIMEOUT=10s\n'
  printf 'INPUT_DNS_FATAL_TIMEOUT=10s\n'
  printf 'INPUT_FTP_SSL_ALLOW=true\n'
  printf 'INPUT_SSL_VERIFY_CERTIFICATE=false\n'
  printf 'INPUT_SSL_CHECK_HOSTNAME=false\n'
  printf 'INPUT_LFTP_SETTINGS=set ftp:ssl-force true;set net:persist-retries 0;set net:max-retries 1;\n'
} > "${_env}"

# --- Step 3: invoke the action ------------------------------------------------
#
# Inlined rather than going through run_action so the scenario is
# self-documenting as the canonical reproducer for the FTPS
# coverage gap that #120 closes. Output captured to a tempfile
# (NOT /dev/null) so the assertions below can grep for the
# success banner AND so a CI failure is debuggable from the
# runner log alone.
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"

log_info "invoking action against explicit FTPS server (port ${FTP_CONTROL_PORT}, AUTH TLS upgrade)"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e

# --- Step 4: assert end-to-end success --------------------------------------
assert_action_success "${_log}" "${_rc}"

# --- Step 5: assert the fixture entries landed on the server ------------------
#
# Same observation path as scenario 08: vsftpd's /home/vsftpd is
# bind-mounted at ${FTP_DATA_DIR}, and the FTP user's home is
# /home/vsftpd/${FTP_USER}. LOCAL_UMASK=022 (set in
# start_ftps_server) makes that directory world-readable, so a
# plain `ls` from the host works regardless of the uid mapping
# inside the container.
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"

rm -f "${_log}"

log_pass "scenario 03 passed: action uploaded fixtures over FTPS explicit (AUTH TLS on port ${FTP_CONTROL_PORT})"

exit 0
