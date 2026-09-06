#!/bin/sh
# tests/integration/scenarios/05-exclude-and-exclude-delete.sh
#
# Scenario 05 (variant B): mirror with --delete + INPUT_EXCLUDE via
# lftp from alpine, against a real vsftpd.
#
# Scope:
#   * Boots docker.io/fauria/vsftpd.
#   * Pre-seeds the FTP user's home with:
#       - one file that does NOT match the source fixtures
#         (extra.html) — this file must be REMOVED by --delete.
#   * The local sample-public-html fixture ships a `local.bak` file
#     so INPUT_EXCLUDE has a real candidate to filter. The action's
#     INPUT_EXCLUDE setting (translated to `set mirror:exclude *.bak`)
#     prevents the file from being uploaded.
#   * Runs lftp with `set mirror:exclude *.bak; mirror --reverse
#     --delete --continue /data/ ./`.
#   * Asserts the three fixture entries are present, extra.html
#     was removed by --delete, and the fixture's local.bak was NOT
#     uploaded (excluded by mirror:exclude).
#
# INPUT_EXCLUDE (-x) vs INPUT_EXCLUDE_DELETE (-X) — keep them
# straight, both flags exist in the action:
#
#   * INPUT_EXCLUDE          → `mirror -x <regex>`  → "files matching
#                            this regex on the LOCAL side are NOT
#                            uploaded" (upload-time filter).
#                            Scenario 05 covers this end-to-end.
#   * INPUT_EXCLUDE_DELETE   → `mirror -X <glob>`   → "files matching
#                            this glob on the REMOTE side are NOT
#                            removed by --delete" (delete-time
#                            filter). Scenario 11 covers this
#                            end-to-end (11-exclude-delete-protects-
#                            remote.sh) by pre-seeding important.bak
#                            on the FTP home and asserting it survives.
#
# INPUT_EXCLUDE_DELETE is intentionally NOT exercised here — it is
# covered end-to-end through the action image in scenario 11
# (11-exclude-delete-protects-remote.sh). Scenario 11 invokes the
# real ftp-deployment-action binary, so it exercises the full
# lib.sh::build_mirror_command path (including the `mirror -X`
# flag the v2.11.0 fix added). Scenario 05 here stays minimal:
# it verifies the lftp primitive (`set mirror:exclude` + `--delete`)
# on which INPUT_EXCLUDE relies, without the action image in the
# loop.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "05-exclude-and-exclude-delete"

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# Sanity: confirm the fixture's INPUT_EXCLUDE target actually exists
# in the bind-mounted sample-public-html/. Without this guard the
# assert_absent below would pass vacuously (closes #165). The F2
# audit regression: a previous version of this scenario removed the
# `local.bak` assertion under the assumption that "INPUT_EXCLUDE
# coverage is in scenario 11" — but scenario 11 sets
# INPUT_EXCLUDE_DELETE=*.bak, NOT INPUT_EXCLUDE=*.bak, so the upload-
# time `-x` flag was left uncovered end-to-end.
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

# Build the lftp script. We use `set mirror:exclude *.bak` to
# protect local *.bak files from being uploaded. lftp 4.9.3
# treats the value as a POSIX regular expression, so we use the
# equivalent `.*\.bak` form. (lftp logs an error on `*.bak`
# itself: "Invalid preceding regular expression".) The fixture's
# `local.bak` is the upload-time probe; scenario 05 asserts that,
# AFTER the mirror, no *.bak file appeared in the FTP home — which
# proves the exclude pattern is in effect end-to-end.
_script=$(mktemp -t lftpscr.XXXXXX) || log_fail "mktemp failed"
lftp_build_open_script "${_script}" \
  "set mirror:exclude '.*\.bak'" \
  "mirror --reverse --delete --continue --verbose=1 /data/ ./"

_log=$(mktemp -t lftplog.XXXXXX) || log_fail "mktemp failed"

# v2.11.9 (#225, #226): register _log and _script in the EXIT
# trap so they are removed on any exit path (success, lftp error,
# assert_present failure, signal). See scenario 01 for the
# rationale and the F2 audit (v2.11.9 +1 day) trap-safety pattern.
trap 'rm -f "${_log:-}" "${_script:-}"; stop_ftp_server' EXIT

log_info "running mirror with mirror:exclude + --delete"
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

# INPUT_EXCLUDE protects *.bak from being uploaded. The fixture
# carries a `local.bak` probe (see the assert_present above) and
# the mirror was invoked with `set mirror:exclude '.*\.bak'`. After
# the mirror, the FTP home must NOT contain `local.bak` — the
# exclude directive filtered it out at upload time. This assertion
# is the load-bearing coverage for INPUT_EXCLUDE (the upload-time
# `-x` flag); INPUT_EXCLUDE_DELETE (the delete-time `-X` flag) is
# covered separately by scenario 11.
assert_absent "${_ftp_home}" "local.bak"

log_pass "scenario 05 passed: --delete removed extra.html; mirror:exclude protected local.bak from upload"

exit 0
