#!/bin/sh
# tests/integration/scenarios/04-ftps-implicit-upload.sh
#
# Scenario 04 (variant C, closes #120 half 2): implicit FTPS upload.
#
#   * Boots docker.io/fauria/vsftpd with implicit_ssl=YES. vsftpd
#     binds 2122 inside the container and expects TLS from the
#     very first byte (no FTP-greeting-then-AUTH-TLS upgrade —
#     the connection is encrypted at the transport layer from the
#     start). The host-side port is also 2122 (unprivileged, no
#     `ip_unprivileged_port_start` workaround needed).
#   * Generates an ephemeral self-signed cert (same helper as
#     scenario 03, see tests/integration/lib/self-signed-cert.sh).
#   * Invokes the ftp-deployment-action image end-to-end with
#     INPUT_SERVER=ftps://ftptest@127.0.0.1:2122. The `ftps://`
#     scheme is what tells lftp to start TLS from byte 0 (no AUTH
#     upgrade). The user is embedded in the URL for the same
#     .netrc-lookup reason scenario 03 documents (acquire_lock_
#     with_recovery does not apply run_lftp_once's URL rewrite).
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
# Why we do NOT fall back to alpine+vsftpd: fauria/vsftpd's
# vsftpd is compiled against libssl/libcrypto (verified via
# `ldd`), and `implicit_ssl` is a standard vsftpd directive —
# the fauria image just does not expose it via env vars. We
# bind-mount a custom vsftpd.conf that sets `implicit_ssl=YES`
# and the entrypoint's append-env-vars step preserves it. No
# reason to drag in a second image and ~30 LoC of db_load
# boilerplate when this works.
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

# MODE="implicit" maps host port $FTP_IMPLICIT_PORT -> container
# port $FTP_IMPLICIT_PORT, with implicit_ssl=YES (TLS from byte
# 0). FTP_IMPLICIT_PORT is exported from
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
# Same user-in-URL / SSL-flag reasoning as scenario 03.
#
# INPUT_MAX_RETRIES=3 (vs 1 in scenarios 08/09/10): defense-in-depth
# against the residual flake mode B from #135 — lftp 4.9.3
# occasionally fails the TLS handshake on the first attempt and
# the action exits 1 before INPUT_MAX_RETRIES can fire on the
# retry path. Cost is ~2-3s of extra CI wall time; eliminates the
# residual flake if the pre-baked image work (closes #135) ever
# regresses on the apk-index race front.
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
# `${VAR:-}` default form so a failure before _log / _env are
# assigned does not abort the trap under `set -u` and leak the FTP
# container. See scenario 03 for the full rationale.
trap 'rm -f "${_env:-}" "${_log:-}" "${FTP_VSFTPD_CONF:-}"; stop_ftp_server' EXIT

{
  printf 'INPUT_SERVER=ftps://%s@127.0.0.1:%s\n' "${FTP_USER}" "${FTP_IMPLICIT_PORT}"
  printf 'INPUT_USER=%s\n' "${FTP_USER}"
  printf 'INPUT_PASSWORD=%s\n' "${FTP_PASSWORD}"
  printf 'INPUT_LOCAL_DIR=/data\n'
  printf 'INPUT_REMOTE_DIR=/\n'
  printf 'INPUT_MAX_RETRIES=3\n'
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
# must not be world-readable. mktemp on alpine busybox defaults to
# mode 0644; chmod 0600 closes the gap (matches tests/integration/
# lib/common.sh:406 for the scenarios that go through
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

log_pass "scenario 04 passed: action uploaded fixtures over FTPS implicit (TLS from byte 0 on port ${FTP_IMPLICIT_PORT})"

exit 0
