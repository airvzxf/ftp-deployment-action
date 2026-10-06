#!/bin/sh
# 21-lftp-output-visible.sh — frozen acceptance scenario.
#
# Business rule: the user must see lftp's own output in the step log.
# The container is destroyed when the step ends, so a log file inside it
# is worthless to the user.
#
# Case A (success):  stdout shows which files were transferred.
# Case B (bad password): exit 1 and stdout shows the server's 530 reply.
# Case C (secrets):  the password never appears in stdout except on the
#                    "::add-mask::" line that tells GitHub to hide it.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "21-lftp-output-visible"
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

show_log() { sed 's/^/    | /' "${_log}" >&2; }

# --- Case A: success shows transferred files --------------------------------
build_action_env_file "${_env}" "${IMAGE}" /data /
set +e
timeout 60 ${RUNTIME} run --rm --network host \
    -v "${FIXTURES_DIR}:/data:ro" --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
assert_action_success "${_log}" "${_rc}"
if ! grep -q "index.html" "${_log}"; then
  show_log; log_fail "A: stdout does not mention index.html (lftp output is hidden)"
fi
if ! grep -q "Transferring file" "${_log}"; then
  show_log; log_fail "A: stdout does not contain lftp's 'Transferring file' lines"
fi
log_info "A ok: transferred files are visible"

# --- Case C (on the success log): password only on the add-mask line -------
_leaks=$(grep -F "${FTP_PASSWORD}" "${_log}" | grep -v '^::add-mask::' || true)
if [ -n "${_leaks}" ]; then
  log_fail "C: password appears in stdout outside ::add-mask:: (${_leaks})"
fi
log_info "C ok: password only on the ::add-mask:: line"

# --- Case B: bad password shows the server reply, is classified as
#     PERMANENT and is not retried (max_retries=3 must still mean 1 try).
build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_PASSWORD=wrong_${FTP_PASSWORD}" "INPUT_MAX_RETRIES=3"
set +e
timeout 90 ${RUNTIME} run --rm --network host \
    -v "${FIXTURES_DIR}:/data:ro" --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
if [ "${_rc}" -ne 1 ]; then
  show_log; log_fail "B: expected exit 1 for a wrong password, got ${_rc}"
fi
if ! grep -q "530" "${_log}"; then
  show_log; log_fail "B: stdout does not show the server's 530 reply"
fi
if grep -q "/home/lftp/.lftp-logs" "${_log}" || grep -qi "log file" "${_log}"; then
  show_log; log_fail "B: failure output still points the user to a log file they cannot reach"
fi
if ! grep -q "PERMANENT" "${_log}"; then
  show_log; log_fail "B: wrong password was not classified as a PERMANENT failure"
fi
_tries=$(grep -c '^Try #' "${_log}" || true)
if [ "${_tries}" -ne 1 ]; then
  show_log; log_fail "B: expected exactly 1 attempt for a wrong password, saw ${_tries}"
fi
log_info "B ok: wrong password shows 530, PERMANENT, 1 attempt"

log_pass "scenario 21 passed: lftp output is visible to the user, password stays masked"
exit 0
