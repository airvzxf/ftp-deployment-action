#!/bin/sh
# tests/integration/scenarios/03-ftps-explicit-upload.sh
#
# Scenario 03 (variant C, closes #120 half 1): explicit FTPS upload.
#
#   * Boots the pre-baked FTPS test-server image (alpine vsftpd, built
#     from tests/integration/Dockerfile.test-server) via
#     start_ftps_server, with SSL/TLS enabled (a custom vsftpd.conf
#     overlay is bind-mounted in, with ssl_enable=YES and the
#     self-signed cert mounted at /etc/vsftpd/vsftpd.pem).
#   * Generates an ephemeral self-signed cert (see
#     tests/integration/lib/self-signed-cert.sh). The cert is
#     rsa:2048 / 1-day / CN=localhost; the action does not verify
#     it (INPUT_SSL_VERIFY_CERTIFICATE=false, INPUT_SSL_CHECK_HOSTNAME=
#     false) so a self-signed cert is sufficient.
#   * Invokes the ftp-deployment-action image end-to-end with
#     INPUT_SERVER=ftp://<user>@127.0.0.1:2121, where <user> is the
#     per-scenario random FTP_USER. The user in the URL is not
#     required: run_lftp_once, acquire_lock_with_recovery and
#     release_lock_safely all pass the URL through rewrite_lftp_url
#     (lib.sh, #132), which embeds INPUT_USER when the URL has none
#     and leaves a URL that already has a user unchanged. Either way
#     lftp sees a user, its .netrc lookup fires, and the password is
#     read from .netrc (B-03). Scenarios 08 and 09 use the bare
#     ftp://host:port form instead, to exercise the rewrite.
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

scenario_setup "03-ftps-explicit-upload"

# --- Step 1: cert + server ---------------------------------------------------
# generate_self_signed_cert prints the absolute path on stdout and
# is idempotent (reuses the cached cert on subsequent runs).
_cert=$(generate_self_signed_cert)
log_info "using cert ${_cert}"

# MODE="explicit": the container runs with --network host, so vsftpd
# listens directly on ${FTP_CONTROL_PORT} (2121) on the host (no port
# mapping takes effect), with ssl_enable=YES (AUTH TLS upgrade on the
# control channel).
start_ftps_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}" "${_cert}" "explicit"

# --- Step 2: env-file --------------------------------------------------------
#
# Critical inputs:
#   * INPUT_SERVER carries the user. This is not required: every
#     lftp the action forks (the mirror, the lock acquire, the
#     sentinel refresh and the lock release) applies
#     rewrite_lftp_url, which is a no-op when
#     the URL already has a user and embeds INPUT_USER when it does
#     not. Scenarios 08 and 09 use the bare form to cover the
#     rewrite; these FTPS scenarios keep the user in the URL.
#   * INPUT_FTP_SSL_ALLOW=true + INPUT_LFTP_SETTINGS with
#     `set ftp:ssl-force true;`: the lftp in the action image
#     sends AUTH TLS with ftp:ssl-allow alone, but if the
#     server refuses it lftp continues in cleartext. ftp:ssl-force
#     makes that refusal fatal, so this scenario sets it to
#     guarantee the session really is TLS.
#   * INPUT_SSL_VERIFY_CERTIFICATE=false / INPUT_SSL_CHECK_HOSTNAME=
#     false: the cert is self-signed and says CN=localhost but the
#     action connects to 127.0.0.1, so neither check can pass on
#     this cert. The action still negotiates TLS (the wire IS
#     encrypted); we only relax the post-handshake identity checks.
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
# `${VAR:-}` default form. The trap is installed after _env is
# assigned (above) but BEFORE _log is assigned (Step 3); if a
# failure fires the trap on the way to that assignment, a bare
# `${_log}` would abort the entire trap string under `set -u`
# before `stop_ftp_server` runs, leaking the FTP container on the
# host. The FTP_VSFTPD_CONF:- default was already this pattern;
# the _log entry follows it, and _env gets the same form.
# Until this trap is installed, the EXIT trap is the one
# scenario_setup set (`trap stop_ftp_server EXIT`). So if the `mktemp`
# for _env fails, log_fail's exit still runs stop_ftp_server, which
# removes the container and the data dir; only the vsftpd conf
# overlay (FTP_VSFTPD_CONF) is left behind.
trap 'rm -f "${_env:-}" "${_log:-}" "${FTP_VSFTPD_CONF:-}"; stop_ftp_server' EXIT

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
  printf 'INPUT_LFTP_SETTINGS=set ftp:ssl-force true;set net:persist-retries 0;\n'
} > "${_env}"
# v2.11.3 (#158): this mktemp runs on the host. GNU coreutils and
# alpine busybox mktemp both create the file with mode 0600
# (measured); chmod 0600 keeps that explicit instead of relying on
# the host's mktemp. INPUT_PASSWORD lives in this file (Docker's
# --env-file reader is the standard `getline` split, not a keyring),
# so the file must stay private for the lifetime of the container.
# Scenarios 01/02/05/07–12 already go through `lftp_build_open_script`
# or `build_action_env_file`, which call chmod 0600; 03/04 inlined the
# write because they put FTP_USER into INPUT_SERVER, and missed the
# chmod. Same pattern as #133's fix in build_action_env_file
# (tests/integration/lib/common.sh).
chmod 0600 "${_env}"

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
# /home/vsftpd/${FTP_USER}. start_ftps_server chmods the data dir
# (and the user's home inside the container) to 0777, so a plain
# `ls` from the host works regardless of the uid mapping inside the
# container.
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
# v2.11.9 (#165): scenario 03 / 04 / 08 historically only
# asserted the top-level files (index.html + about.html). The
# sample-public-html fixture includes an assets/ subdirectory
# and the mirror uploads its contents; assert it explicitly so a
# regression in mirror's directory handling surfaces here
# instead of being caught downstream.
assert_present "${_ftp_home}" "assets"

assert_server_alive

log_pass "scenario 03 passed: action uploaded fixtures over FTPS explicit (AUTH TLS on port ${FTP_CONTROL_PORT})"

exit 0
