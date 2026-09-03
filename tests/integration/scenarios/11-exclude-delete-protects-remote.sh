#!/bin/sh
# tests/integration/scenarios/11-exclude-delete-protects-remote.sh
#
# Scenario 11 — action-driven INPUT_EXCLUDE_DELETE end-to-end
# (closes #131). Boots a real vsftpd, pre-seeds the FTP user's home
# with TWO files that are NOT in the local fixture, then invokes the
# ftp-deployment-action image with INPUT_DELETE=true AND
# INPUT_EXCLUDE_DELETE='*.bak'. The action must:
#
#   1. Upload the three fixture entries (index.html, about.html,
#      assets/). The fixture is the same sample-public-html/ used by
#      scenarios 01, 02, 05, 08.
#   2. Remove `stale.html` (NOT in fixture, does NOT match the
#      exclude_delete pattern). Proves `mirror --delete` ran.
#   3. PRESERVE `important.bak` (NOT in fixture, MATCHES the
#      exclude_delete pattern). Proves the new `set -a; set
#      mirror:exclude-file ...; set -a;` directive from
#      lib.sh::build_ftp_settings reaches lftp and lftp honours it
#      (closes #131).
#
# Why this scenario exists:
#
#   Pre-fix (v2.11.0 and earlier), `lib.sh::build_ftp_settings`
#   emitted a plain `set mirror:exclude-file <value>;` for
#   INPUT_EXCLUDE_DELETE. lftp 4.9.3 (pinned in Dockerfile) hides
#   that variable behind the `set -a` toggle — without the toggle
#   on, lftp logs `mirror:exclude-file: no such variable. Use 'set
#   -a' to look at all variables.` and silently ignores the
#   directive. The action exits 0 with the success banner, the
#   *.bak file is gone, and the user has silently lost data.
#
#   The fix (this scenario is part of the fix): `build_ftp_settings`
#   now wraps the assignment in `set -a; set mirror:exclude-file
#   <value>; set -a;` (toggle on for the one write, off again so
#   the rest of the chain behaves normally). See #131.
#
#   This scenario is the regression guard: if a future change
#   drops the `set -a; ...; set -a;` wrapping (or stops emitting
#   the directive at all), the action runs lftp against a real
#   vsftpd and the `important.bak` assertion below fires. Pre-fix
#   the .bak file was deleted and assert_present failed; post-fix
#   it is preserved and the scenario is green.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "11-exclude-delete-protects-remote"

# --- Step 1: start the FTP server -------------------------------------------
# Same harness as scenarios 01/02/05/08: docker.io/fauria/vsftpd with a
# per-scenario virtual user. The bind-mounted data dir is what we read
# from the host to assert the post-action state.
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

# --- Step 2: pre-seed the FTP user's home -----------------------------------
#
# Two files, neither in the local fixture:
#
#   * stale.html       — generic leftover from a previous deploy.
#                        Does NOT match the exclude_delete pattern;
#                        must be REMOVED by mirror --delete. Proves
#                        --delete is actually being honoured by the
#                        action (the half that v2.11.0 already
#                        worked for).
#
#   * important.bak    — a remotely-managed artifact (the canonical
#                        example in the action.yml description:
#                        "files matching these patterns are still
#                        uploaded if present locally, but are not
#                        removed by --delete"). Matches *.bak;
#                        must SURVIVE the mirror --delete pass. The
#                        whole point of INPUT_EXCLUDE_DELETE.
#
# Both files are written directly to the bind-mounted data dir, NOT
# via FTP, so we know the pre-state is what we expect before lftp
# runs (no race between upload and assertion). start_ftp_server
# chmods the FTP user home to 0777 inside the container so the host
# ls / assert_present / assert_absent helpers work across the
# rootless uid mapping.
printf '%s\n' 'leftover from previous deploy' > "${_ftp_home}/stale.html"
chmod 0644 "${_ftp_home}/stale.html" 2>/dev/null || true
printf '%s\n' 'remotely-managed artifact, must survive --delete' \
  > "${_ftp_home}/important.bak"
chmod 0644 "${_ftp_home}/important.bak" 2>/dev/null || true

# Sanity: both seeds landed on the bind mount.
assert_present "${_ftp_home}" "stale.html"
assert_present "${_ftp_home}" "important.bak"

# --- Step 3: build the env-file ---------------------------------------------
#
# Same shape as scenario 08. The two extra INPUT_* values are the
# levers we are testing:
#
#   * INPUT_DELETE=true         — turns on `mirror --delete`, which
#                                 removes stale.html from the
#                                 remote and would also remove
#                                 important.bak without the next
#                                 input.
#   * INPUT_EXCLUDE_DELETE='*.bak' — globs the .bak file (and
#                                 nothing else); the action must
#                                 translate this into the new
#                                 `set -a; set mirror:exclude-file
#                                 *.bak; set -a;` directive and
#                                 lftp must honour it.
#
# All other inputs are inherited from build_action_env_file's defaults
# (plain FTP, the sample-public-html fixture mounted at /data,
# INPUT_REMOTE_DIR=/ which maps to the FTP user's home).
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
trap 'rm -f "${_env}"; stop_ftp_server' EXIT

build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_DELETE=true" \
  "INPUT_EXCLUDE_DELETE=*.bak"

# DEBUG: dump the env-file to confirm what we hand to docker.
log_info "DEBUG env-file contents ($(wc -l < "${_env}" 2>/dev/null) lines):"
sed 's/^/    /' "${_env}"

# --- Step 4: invoke the action image ----------------------------------------
#
# run_action bind-mounts FIXTURES_DIR at /data:ro, shares the host
# network namespace so lftp can reach the vsftpd control port and
# the PASV data port range, and forwards the env-file. Output is
# captured to a tempfile so the post-assertions can grep the log
# if something goes wrong.
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"

log_info "invoking action with INPUT_DELETE=true INPUT_EXCLUDE_DELETE='*.bak' (log=${_log})"
_rc=0
run_action "${IMAGE}" "${_env}" 60 "${_log}" || _rc=$?

# --- Step 5: assert end-to-end success --------------------------------------
#
# Same dual-signal pattern as scenario 08: the action must exit 0
# AND print the `FTP UPLOADED FINISHED` banner. Either failure dumps
# the captured log to stderr before exiting so a regression is
# debuggable from the runner log alone.
assert_action_success "${_log}" "${_rc}"

# --- Step 6: assert the FTP server state -------------------------------------
#
# The three fixture entries must be present (the action uploaded
# them), stale.html must be gone (proves mirror --delete ran), and
# IMPORTANTLY important.bak must STILL be there (proves
# INPUT_EXCLUDE_DELETE protected it — closes #131). The third
# assertion is the load-bearing one for this scenario; the first
# two are controls that catch a broken --delete in the same run.
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

assert_absent "${_ftp_home}" "stale.html"
assert_present "${_ftp_home}" "important.bak"

rm -f "${_log}"

log_pass "scenario 11 passed: INPUT_EXCLUDE_DELETE='*.bak' protected important.bak from mirror --delete (closes #131)"

exit 0