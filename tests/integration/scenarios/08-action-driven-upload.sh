#!/bin/sh
# tests/integration/scenarios/08-action-driven-upload.sh
#
# Scenario 08 (variant C): action-driven upload against a real FTP server.
#
#   * Boots docker.io/fauria/vsftpd with virtual user credentials.
#   * Invokes the ftp-deployment-action image end-to-end with
#     INPUT_SERVER=ftp://127.0.0.1:<port> (NO user embedded in the URL)
#     so the scenario is the canonical reproducer for the bug #124.
#   * Asserts the action exits 0 AND emits the success banner
#     `FTP UPLOADED FINISHED`, AND the fixture entries are present
#     in the FTP user's home on the server.
#
# Why this scenario exists (closes the long-standing variant-B
# workaround in tests/integration/README.md):
#
#   lftp 4.9.3 (pinned in the Dockerfile) only consults ~/.netrc when
#   the URL has BOTH a scheme AND an embedded user — the guard at
#   src/commands.cc:1055 in upstream lftp is `(user || no_proto)`.
#   When INPUT_SERVER arrives as `ftp://host:port` with no user,
#   lftp falls back to `USER anonymous` and never reads the .netrc
#   the action wrote in lib.sh::write_netrc. The action therefore
#   could not talk to a real FTP server — every prior scenario that
#   "talked to FTP" ran the lftp mirror from a fresh alpine
#   container instead (variant B).
#
#   The fix (v2.11.0, closes #124): lib.sh::run_lftp_once now takes
#   the action's INPUT_USER as its 11th positional parameter and,
#   when the URL has a scheme but no embedded user, rewrites it
#   to `scheme://<user>@host:port` before invoking lftp. The user
#   in the URL is what flips the `(user || no_proto)` guard to the
#   `user` branch; lftp then performs NetRC::LookupHost and pulls
#   the password from the .netrc the action wrote (B-03 is
#   preserved: the password still comes from .netrc, only the
#   user — which is documented safe to expose in the URL — is in
#   argv).
#
#   When the URL already carries a user (`scheme://user@host:...`),
#   the function leaves it untouched. URLs without a scheme
#   (`host:port`) go through lftp's own open code, which already
#   does netrc lookup; we do not interfere with that case either.

set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "08-action-driven-upload"

# --- Step 1: start the FTP server -------------------------------------------
# Same harness as scenarios 01/02/05/07. The FTP server is required
# because the action validates INPUT_SERVER as part of its normal
# startup, and we want to observe the result of an actual upload
# (the assertions at the bottom read from FTP_DATA_DIR).
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

# --- Step 2: build the env-file ---------------------------------------------
#
# We use build_action_env_file from common.sh. The crucial inputs
# are:
#   * INPUT_SERVER=ftp://127.0.0.1:<port>     <-- NO user embedded
#   * INPUT_USER=<FTP_USER>                   <-- comes via the env
#                                                 file; run_lftp_once
#                                                 reads it as its 11th
#                                                 positional parameter
#                                                 and rewrites the URL.
#   * INPUT_PASSWORD=<FTP_PASSWORD>           <-- goes to .netrc via
#                                                 lib.sh::write_netrc
#                                                 (B-03). Never on argv.
#   * INPUT_LOCAL_DIR=/data                   <-- bind-mounted
#                                                 fixture dir.
#   * INPUT_REMOTE_DIR=/                      <-- vsftpd user home.
#   * INPUT_MAX_RETRIES=1                     <-- fast failure.
#   * INPUT_FTP_SSL_ALLOW=false               <-- plain FTP only.
_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
# v2.11.9 (#225): _log is included in the trap so the captured
# action log is removed on any exit path, not just the success
# branch. See scenarios 01 / 03 for the rationale.
#
# F2 audit (v2.11.9 +1 day): use :- defaults for _env and _log so
# a failure before either is assigned does not abort the trap under
# `set -u` and leak the FTP container. See scenario 03.
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

build_action_env_file "${_env}" "${IMAGE}" /data /

# --- Step 3: invoke the action image ----------------------------------------
#
# Same shape as the run_action helper in common.sh, but inlined so
# the scenario stays self-documenting (this is the canonical
# reproducer for the bug from #124 and a future developer reading
# this file should see exactly what the test does). Output is
# captured to a tempfile (NOT /dev/null) so the assertions below
# can grep for the success banner.
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"

log_info "invoking action with INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT} (no embedded user)"
set +e
timeout 60 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e

# --- Step 4: assert end-to-end success --------------------------------------
#
# assert_action_success combines the two halves of "the bug from
# #124 is closed":
#   * the action container exited 0 (lftp connected, transferred
#     the fixtures, and quit cleanly), AND
#   * the captured log contains `FTP UPLOADED FINISHED`, the
#     banner the entrypoint prints on the success branch.
# Either failure dumps the captured log to stderr before exiting,
# so a regression here is debuggable from the runner log alone.
assert_action_success "${_log}" "${_rc}"

# --- Step 5: assert the fixture entries landed on the server -----------------
#
# We observe the server state through the bind-mounted
# ${FTP_DATA_DIR}, exactly as scenarios 01 and 02 do. FTP_USER's
# home is ${FTP_DATA_DIR}/${FTP_USER} (vsftpd's /home/vsftpd is
# bind-mounted there). LOCAL_UMASK=022 (set in start_ftp_server)
# makes the FTP user home directory world-readable, so a plain
# `ls` from the host works regardless of the uid mapping inside
# the container.
_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
# v2.11.9 (#165): see scenario 03 — also assert the assets/
# subdirectory landed on the server.
assert_present "${_ftp_home}" "assets"

log_pass "scenario 08 passed: action uploaded fixtures to ftp://127.0.0.1:${FTP_CONTROL_PORT} via .netrc (bug #124 closed)"

exit 0