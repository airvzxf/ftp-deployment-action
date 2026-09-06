#!/bin/sh
# tests/integration/scenarios/02-plain-ftp-delete.sh
#
# Scenario 02 (variant B): plain FTP upload + delete via lftp from
# alpine, against a real vsftpd.
#
#   * Boots docker.io/fauria/vsftpd with virtual user credentials.
#   * Pre-seeds the FTP user's home with a stale file (stale.html)
#     that is NOT in the local fixture directory. The stale file
#     must be removed by the `mirror --reverse --delete` invocation.
#   * Runs lftp with `mirror --reverse --delete --continue` against
#     the sample-public-html fixture.
#   * Asserts the three fixture entries are present AND the stale
#     entry is absent.
#
# This is the first scenario that exercises lftp's --delete flag
# end-to-end. It is the foundation for scenario 05 (which builds on
# --delete + --exclude-file to protect specific globs).
#
# Variant B rationale: see scenario 01. The action image's lftp
# 4.9.3 doesn't honor .netrc, so we drive lftp directly from alpine.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "02-plain-ftp-delete"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

# Pre-seed the FTP user's home with a stale file. This emulates the
# real-world scenario where the server has leftover files from a
# previous deploy that the new deploy should clean up. The file is
# written DIRECTLY to the bind-mounted data directory (NOT via FTP)
# so we know it exists BEFORE lftp runs, removing any ambiguity in
# the post-assertion check.
#
# start_ftp_server chmods /home/vsftpd/${FTP_USER} to 0777 inside
# the container so we can ls/read it from the host despite the
# rootless uid mapping; that's what makes this pre-seed work.
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"
printf '%s\n' 'leftover from previous deploy' > "${_ftp_home}/stale.html"
chmod 0644 "${_ftp_home}/stale.html" 2>/dev/null || true
assert_present "${_ftp_home}" "stale.html"

# Build the lftp script. --delete is the documented lftp mirror
# flag that removes remote files not present at the source.
_script=$(mktemp -t lftpscr.XXXXXX) || log_fail "mktemp failed"
lftp_build_open_script "${_script}" \
  "mirror --reverse --delete --continue --verbose=1 /data/ ./"

_log=$(mktemp -t lftplog.XXXXXX) || log_fail "mktemp failed"

# v2.11.9 (#225, #226): register _log and _script in the EXIT
# trap so they are removed on any exit path (success, lftp error,
# assert_present failure, signal). See scenario 01 for the
# rationale and the F2 audit (v2.11.9 +1 day) trap-safety pattern.
trap 'rm -f "${_log:-}" "${_script:-}"; stop_ftp_server' EXIT

log_info "running mirror upload with --delete (log=${_log})"
if lftp_run_script "${_script}" "${_log}" 60; then
  _rc=0
else
  _rc=$?
fi

if [ "${_rc}" -ne 0 ]; then
  printf '%s\n' "---- captured lftp log (exit ${_rc}) ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of lftp log ----" >&2
  log_fail "lftp mirror --delete exited with code ${_rc}"
fi

# --- Assertions on the FTP server state --------------------------------------

# Fixture entries should be present (mirror uploaded them).
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

# Stale entry should be absent (--delete removed it).
assert_absent "${_ftp_home}" "stale.html"

log_pass "scenario 02 passed: --delete removed stale.html while keeping fixture entries"

exit 0
