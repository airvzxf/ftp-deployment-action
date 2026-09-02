#!/bin/sh
# tests/integration/scenarios/01-plain-ftp-upload.sh
#
# Scenario 01 (variant B): plain FTP upload via lftp from alpine.
#
#   * Boots docker.io/fauria/vsftpd with virtual user credentials.
#   * Runs an alpine + lftp container that mirrors the bind-mounted
#     sample-public-html fixture to the FTP user's home via
#     `mirror --reverse`.
#   * Asserts that the three fixture entries (index.html, about.html,
#     assets/) are present in the FTP user's home directory on the
#     server, as observed via the bind-mounted data directory.
#
# This is the foundation scenario: every other scenario that needs
# an FTP server in a known state runs through scenario 01 first (or
# does its own start_ftp_server + assert_present dance).
#
# Variant B rationale: the original proposal called for the
# ftp-deployment-action image to do the upload. That requires lftp
# 4.9.3 (the version pinned in the Dockerfile) to honor .netrc for
# FTP URLs without embedded credentials, which it does not — see
# tests/integration/README.md "Why variant B". The harness stays
# faithful to the production control-plane (same FTP server image,
# same lftp version, same PASV configuration) but performs the
# actual mirror from a fresh alpine container, where we control the
# invocation directly.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "01-plain-ftp-upload"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

# Build the lftp script. The `mirror --reverse` upload direction
# (local -> remote) is what lftp's mirror calls "reverse". The
# trailing slash matters: lftp mirrors the directory's CONTENTS,
# not the directory itself, when both sides end with a slash.
_script=$(mktemp -t lftpscr.XXXXXX) || log_fail "mktemp failed"
lftp_build_open_script "${_script}" \
  "mirror --reverse --verbose=1 --continue /data/ ./"

_log=$(mktemp -t lftplog.XXXXXX) || log_fail "mktemp failed"

log_info "running mirror upload (log=${_log})"
if lftp_run_script "${_script}" "${_log}" 60; then
  _rc=0
else
  _rc=$?
fi

rm -f "${_script}"

# Same fail-loud contract as assert_action_success: on non-zero rc
# we dump the captured log to stderr before exit 1, so the failure
# is debuggable from the runner log alone.
if [ "${_rc}" -ne 0 ]; then
  printf '%s\n' "---- captured lftp log (exit ${_rc}) ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of lftp log ----" >&2
  log_fail "lftp upload exited with code ${_rc}"
fi
rm -f "${_log}"

# --- Assertions on the FTP server state --------------------------------------
#
# We observe the server state through the bind-mounted
# ${FTP_DATA_DIR} (vsftpd's /home/vsftpd is bind-mounted there, and
# the FTP user's home is /home/vsftpd/${FTP_USER}). LOCAL_UMASK=022
# (set in start_ftp_server) makes the FTP user home directory
# world-readable, so a plain `ls` from the host works regardless of
# the uid mapping inside the container.
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

log_pass "scenario 01 passed: 3 fixture entries uploaded to ftp://${FTP_USER}@127.0.0.1:${FTP_CONTROL_PORT}/"

exit 0
