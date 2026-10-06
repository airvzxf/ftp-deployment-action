#!/bin/sh
# 20-action-yml-defaults.sh — frozen acceptance scenario.
#
# Business rule: a user who sets ONLY the required inputs gets a working
# deployment. GitHub injects every action.yml default as INPUT_*; this
# scenario does the same (instead of the hand-picked env the other
# scenarios use), uploads to remote_dir "/" and must finish quickly.
#
# Expected:   exit 0, "FTP UPLOADED FINISHED" banner, fixtures on the
#             server, wall-clock < 60 s.
# Not expected: timeout (exit 124) — that is the #334 hang caused by
#             net_max_retries=0 in action.yml.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "20-action-yml-defaults"
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

# Every action.yml default, exactly as GitHub would inject it.
awk '
  /^inputs:/                { in_inputs = 1; next }
  /^[^ ]/                   { in_inputs = 0 }
  in_inputs && /^  [a-z_]+:[ ]*$/ { name = $1; sub(":", "", name); next }
  in_inputs && /^    default:/ {
    v = $0
    sub(/^    default:[ ]*/, "", v)
    if (v ~ /^\x27.*\x27$/) { v = substr(v, 2, length(v) - 2); gsub(/\x27\x27/, "\x27", v) }
    print "INPUT_" toupper(name) "=" v
  }
' "${ROOT}/action.yml" > "${_env}"
{
  printf '%s\n' "INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT}"
  printf '%s\n' "INPUT_USER=${FTP_USER}"
  printf '%s\n' "INPUT_PASSWORD=${FTP_PASSWORD}"
  printf '%s\n' "INPUT_LOCAL_DIR=/data"
  printf '%s\n' "INPUT_REMOTE_DIR=/"
} >> "${_env}"
chmod 0600 "${_env}"

log_info "env passed to the action (password redacted):"
sed 's/^INPUT_PASSWORD=.*/INPUT_PASSWORD=***/' "${_env}" | sed 's/^/    /'

_start=$(date +%s)
set +e
timeout 90 ${RUNTIME} run --rm \
    --network host \
    -v "${FIXTURES_DIR}:/data:ro" \
    --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
_elapsed=$(( $(date +%s) - _start ))
log_info "action exit code ${_rc} after ${_elapsed}s"

if [ "${_rc}" -eq 124 ]; then
  sed 's/^/    | /' "${_log}" >&2
  log_fail "action hung with action.yml defaults (timeout after 90 s) — see #334"
fi
assert_action_success "${_log}" "${_rc}"
[ "${_elapsed}" -lt 60 ] || log_fail "action took ${_elapsed}s with action.yml defaults (expected < 60 s)"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"
assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "about.html"
assert_present "${_ftp_home}" "assets"

log_pass "scenario 20 passed: only-required-inputs deployment works with action.yml defaults"
exit 0
