#!/bin/sh
# tests/integration/scenarios/05-mirror-delete-and-exclude-glob.sh
#
# Scenario 05: the lftp primitive the action builds for `delete: true`
# plus `exclude`, run with lftp directly (variant B, no action image)
# against a real vsftpd.
#
#   * The FTP home is pre-seeded with extra.html, which is not in the
#     local fixture: `--delete` must remove it.
#   * The local fixture ships local.bak: `-X '*.bak'` (the glob form
#     build_mirror_command emits for `exclude: "*.bak"`) must keep it
#     from being uploaded.
#
# Scenario 23 covers the same input through the action image, including
# server-only files that `-X` protects from `--delete`.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "05-mirror-delete-and-exclude-glob"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Sanity: the exclude target must exist in the fixture, or the
# assert_absent below would pass vacuously (#165).
assert_present "${FIXTURES_DIR}" "local.bak"

# Pre-seed: drop an extra.html on the FTP user's home that is NOT
# in the local fixture. The mirror with --delete should remove it.
# We use `docker exec` so the file is owned by ftp:ftp (the same
# ownership that vsftpd expects for virtual-user home content) and
# the bind-mount's uid-mapping complication does not matter.
${RUNTIME} exec "${FTP_CONTAINER_NAME}" /bin/sh -c "
printf 'pre-existing extra file\n' > '/home/vsftpd/${FTP_USER}/extra.html'
chown ftp:ftp '/home/vsftpd/${FTP_USER}/extra.html'
chmod 644 '/home/vsftpd/${FTP_USER}/extra.html'
"

# Sanity: confirm the pre-seed landed on the bind-mount.
assert_present "${_ftp_home}" "extra.html"

# `-X <glob>` is what build_mirror_command emits for each `exclude`
# item; the single quotes keep lftp from expanding the glob locally.
_script=$(mktemp -t lftpscr.XXXXXX) || log_fail "mktemp failed"
lftp_build_open_script "${_script}" \
  "" \
  "mirror --reverse --delete --continue --verbose=1 -X '*.bak' /data/ ./"

_log=$(mktemp -t lftplog.XXXXXX) || log_fail "mktemp failed"

# v2.11.9 (#225, #226): register _log and _script in the EXIT
# trap so they are removed on any exit path (success, lftp error,
# assert_present failure, signal). See scenario 01 for the
# rationale and the F2 audit (v2.11.9 +1 day) trap-safety pattern.
trap 'rm -f "${_log:-}" "${_script:-}"; stop_ftp_server' EXIT

log_info "running mirror --delete -X '*.bak'"
if lftp_run_script "${_script}" "${_log}" 60; then
  _rc=0
else
  _rc=$?
fi

if [ "${_rc}" -ne 0 ]; then
  printf '%s\n' "---- captured lftp log (exit ${_rc}) ----" >&2
  cat "${_log}" >&2
  printf '%s\n' "---- end of lftp log ----" >&2
  log_fail "lftp mirror exited with code ${_rc}"
fi

# --- Assertions on the FTP server state --------------------------------------

# Fixture entries should be present (mirror uploaded them).
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

# Sanity: extra.html was NOT in the source, so --delete must have
# removed it.
assert_absent "${_ftp_home}" "extra.html"

# `-X '*.bak'` kept the fixture's local.bak from being uploaded.
assert_absent "${_ftp_home}" "local.bak"

log_pass "scenario 05 passed: --delete removed extra.html; -X '*.bak' kept local.bak from being uploaded"

exit 0
