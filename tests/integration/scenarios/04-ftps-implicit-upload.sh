#!/bin/sh
# tests/integration/scenarios/04-ftps-implicit-upload.sh
#
# Scenario 04 (variant C, closes #120 half 2): implicit FTPS upload.
#
#   * Boots the pre-baked FTPS test-server image (alpine vsftpd, built
#     from tests/integration/Dockerfile.test-server) via
#     start_ftps_server, with implicit_ssl=YES. The container runs
#     with --network host, so vsftpd listens directly on
#     ${FTP_IMPLICIT_PORT} (2122) on the host and expects TLS from
#     the very first byte (no FTP-greeting-then-AUTH-TLS upgrade —
#     the connection is encrypted at the transport layer from the
#     start). The port is unprivileged, so no
#     `ip_unprivileged_port_start` workaround is needed.
#   * Generates an ephemeral self-signed cert (same helper as
#     scenario 03, see tests/integration/lib/self-signed-cert.sh).
#   * Invokes the ftp-deployment-action image end-to-end with
#     INPUT_SERVER=ftps://<user>@127.0.0.1:2122, where <user> is the
#     per-scenario random FTP_USER. The `ftps://` scheme is what
#     tells lftp to start TLS from byte 0 (no AUTH upgrade). The
#     user in the URL is not required (rewrite_lftp_url embeds
#     INPUT_USER when it is missing, for every lftp the action
#     forks); see scenario 03.
#   * INPUT_FTP_SSL_ALLOW=true / INPUT_SSL_VERIFY_CERTIFICATE=
#     false / INPUT_SSL_CHECK_HOSTNAME=false: same rationale as
#     scenario 03 — the cert is self-signed /CN=localhost.
#   * Asserts the action exits 0 AND emits `FTP UPLOADED FINISHED`
#     AND the fixture entries are present on the server.
#
# Why "implicit" is a separate scenario (and not just a flag on
# scenario 03): implicit FTPS changes the protocol shape
# fundamentally — the server's first byte is TLS, not a 220
# greeting. lftp's behaviour, the `ftps://` scheme, the port
# conventionally used (990; we use 2122 to stay unprivileged on
# the host), and `implicit_ssl=YES` on the server side are all
# distinct from explicit FTPS. A test that covers both surfaces
# them as separate scenarios so a regression in either branch is
# pinpointed by the scenario that failed, not by a flag inside
# scenario 03.
#
# Why a bind-mounted vsftpd.conf: `implicit_ssl` is a standard
# vsftpd directive. start_ftps_server bind-mounts an overlay
# vsftpd.conf (written by _write_ftps_vsftpd_conf in
# tests/integration/lib/self-signed-cert.sh) that sets
# `implicit_ssl=YES` for MODE="implicit"; the same image and helper
# serve scenario 03, where the directive is omitted.
#
# v2.11.9 (#232): the action's captured log (_log) and the
# per-scenario env-file (_env) are cleaned up by the EXIT trap
# installed below ("trap ... EXIT"). On the success path the
# linear `rm -f "${_log}"` was previously the only cleanup; on
# the failure path the log was dumped to stderr for debuggability
# but then leaked on disk. The trap closes the leak on all exit
# paths (success, assertion failure, lftp timeout, signal).

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"
# shellcheck source=tests/integration/lib/self-signed-cert.sh
. "${COMMON}/self-signed-cert.sh"

scenario_setup "04-ftps-implicit-upload"

# --- Step 1: cert + server ---------------------------------------------------
_cert=$(generate_self_signed_cert)
log_info "using cert ${_cert}"

# MODE="implicit": under --network host vsftpd listens directly on
# $FTP_IMPLICIT_PORT on the host, with implicit_ssl=YES (TLS from
# byte 0). FTP_IMPLICIT_PORT is exported from
# tests/integration/lib/self-signed-cert.sh (default 2122) so the
# port literal lives in exactly one place; the INPUT_SERVER URL
# below reads from the same variable. The shared PASV range is
# the same as explicit FTPS — both modes negotiate data
# connections on the same data ports.
start_ftps_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}" "${_cert}" "implicit"

# --- Step 2: env-file --------------------------------------------------------
#
# ftps:// (NOT ftp://): lftp treats ftps:// as "TLS from byte 0",
# which is what implicit FTPS expects on the wire.
#
# Same user-in-URL (optional, not required) / SSL-flag reasoning as
# scenario 03.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env failed"
# FTP_VSFTPD_CONF is the overlay vsftpd.conf bind-mounted into the
# FTPS container (exported by start_ftps_server). Cleanup mirrors
# the pattern start_ftp_server uses for plain-FTP scenarios (where
# the data dir is the only per-scenario helper state). Use the
# :- default so the trap is safe when start_ftps_server failed
# before exporting FTP_VSFTPD_CONF (e.g. mktemp vsftpd.conf failed).
# v2.11.9 (#225): _log is included so the captured action log is
# removed on any exit path (success, assertion failure, signal),
# not just the success branch.
#
# F2 audit (v2.11.9 +1 day): every variable in the trap uses the
# `${VAR:-}` default form so a failure before _log is assigned does
# not abort the trap under `set -u` and leak the FTP container. The
# trap is installed after _env is assigned; until then the EXIT trap
# is scenario_setup's `trap stop_ftp_server EXIT`, so a failing
# `mktemp` for _env still removes the container and the data dir and
# leaves only the vsftpd conf overlay behind. See scenario 03 for the
# full rationale.
trap 'rm -f "${_env:-}" "${_log:-}" "${FTP_VSFTPD_CONF:-}"; stop_ftp_server' EXIT

{
  printf 'INPUT_SERVER=ftps://%s@127.0.0.1:%s\n' "${FTP_USER}" "${FTP_IMPLICIT_PORT}"
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
  # Implicit FTPS uses the ftps:// scheme, which causes lftp to
  # start TLS from byte 0 without an AUTH upgrade. The same
  # ssl-force flag is therefore a no-op here (TLS is already
  # mandatory on the wire), but we keep it set for symmetry with
  # scenario 03 — if a future lftp release decides to skip the
  # TLS handshake on ftps:// for any reason, ssl-force prevents
  # a silent plaintext fallback.
  printf 'INPUT_LFTP_SETTINGS=set ftp:ssl-force true;set net:persist-retries 0;\n'
} > "${_env}"
# v2.11.3 (#158): see scenario 03 — INPUT_PASSWORD in this tmpfile
# must not be readable by other users. This mktemp runs on the host;
# GNU coreutils and alpine busybox mktemp both create the file with
# mode 0600 (measured), and chmod 0600 keeps that explicit instead
# of relying on the host's mktemp (matches build_action_env_file in
# tests/integration/lib/common.sh for the scenarios that go through
# lftp_build_open_script / build_action_env_file).
chmod 0600 "${_env}"

# --- Step 3: invoke the action ------------------------------------------------
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"

log_info "invoking action against implicit FTPS server (port ${FTP_IMPLICIT_PORT}, TLS from byte 0)"
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
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
# v2.11.9 (#165): see scenario 03 — also assert the assets/
# subdirectory landed on the server.
assert_present "${_ftp_home}" "assets"

assert_server_alive

log_pass "scenario 04 passed: action uploaded fixtures over FTPS implicit (TLS from byte 0 on port ${FTP_IMPLICIT_PORT})"

exit 0
