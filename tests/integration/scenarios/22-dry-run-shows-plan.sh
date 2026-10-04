#!/bin/sh
# 22-dry-run-shows-plan.sh — frozen acceptance scenario.
#
# Business rule: dry_run lets the user SEE what would be uploaded,
# without touching the server.
#
# Expected:   exit 0, "DRY RUN COMPLETED" banner, stdout lists the
#             fixture files, the server directory stays empty.
# Not expected: an empty plan (lftp output hidden) or files on the server.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "22-dry-run-shows-plan"
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
trap 'rm -f "${_env:-}" "${_log:-}"; stop_ftp_server' EXIT

build_action_env_file "${_env}" "${IMAGE}" /data / "INPUT_DRY_RUN=true"
set +e
timeout 60 ${RUNTIME} run --rm --network host \
    -v "${FIXTURES_DIR}:/data:ro" --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e

if [ "${_rc}" -ne 0 ]; then
  sed 's/^/    | /' "${_log}" >&2; log_fail "dry run exited ${_rc}"
fi
grep -q "DRY RUN COMPLETED" "${_log}" || { sed 's/^/    | /' "${_log}" >&2; log_fail "missing DRY RUN banner"; }
for _f in index.html about.html; do
  if ! grep -q "${_f}" "${_log}"; then
    sed 's/^/    | /' "${_log}" >&2
    log_fail "dry-run plan does not mention ${_f} (the user sees no plan)"
  fi
done

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"
assert_absent "${_ftp_home}" "index.html"
assert_absent "${_ftp_home}" "about.html"

log_pass "scenario 22 passed: dry run shows the plan and changes nothing"
exit 0
